import {test} from 'node:test';
import assert from 'node:assert/strict';
import {FolderStore, writeText, readText, hash} from '../web/storage.mjs';

const notFound = () => Object.assign(new Error('not found'), {name: 'NotFoundError'});
class Directory {
  constructor(name = 'selected') { this.kind = 'directory'; this.name = name; this.entries = new Map(); this.failWrite = false; }
  async getDirectoryHandle(name, {create = false} = {}) {
    if (!this.entries.has(name) && create) this.entries.set(name, new Directory(name));
    const value = this.entries.get(name); if (!value) throw notFound();
    if (value.kind !== 'directory') throw new Error('type mismatch'); return value;
  }
  async getFileHandle(name, {create = false} = {}) {
    if (!this.entries.has(name) && create) this.entries.set(name, {kind: 'file', name, text: ''});
    const value = this.entries.get(name); if (!value) throw notFound();
    if (value.kind !== 'file') throw new Error('type mismatch');
    return {getFile: async () => ({text: async () => value.text}), createWritable: async () => {
      let pending;
      return {write: async text => { pending = text; }, close: async () => {
        if (this.failWrite) throw new Error('disk full'); value.text = pending;
      }, abort: async () => {}};
    }};
  }
  async *values() { yield* this.entries.values(); }
  async removeEntry(name) {
    const entry = this.entries.get(name); if (!entry) throw notFound();
    if (entry.kind === 'directory' && entry.entries.size) throw Object.assign(new Error('not empty'), {name: 'InvalidModificationError'});
    this.entries.delete(name);
  }
}
const payload = n => JSON.stringify({format: 'chagok-device', version: 1, ledger: 'l', changes: [], local: {n}});
async function setup() { const parent = new Directory(); const store = await FolderStore.open(parent); await store.load(); return {parent, store}; }

test('alternating slots retain the latest valid generation across reopen', async () => {
  const {parent, store} = await setup();
  await store.save(payload(1)); await store.save(payload(2));
  const reopened = await FolderStore.open(parent);
  assert.equal(await reopened.load(), payload(2)); assert.equal(reopened.generation, 2);
});
test('interrupted close keeps the prior checkpoint readable and permits retry', async () => {
  const {parent, store} = await setup(); await store.save(payload(1)); await store.save(payload(2));
  store.dir.failWrite = true;
  await assert.rejects(store.save(payload(3)), /disk full/);
  const reopened = await FolderStore.open(parent); assert.equal(await reopened.load(), payload(2));
  store.dir.failWrite = false; await store.save(payload(3));
  assert.equal(await (await FolderStore.open(parent)).load(), payload(3));
});
test('failure on the first write removes only its empty placeholder and can retry', async () => {
  const {parent, store} = await setup(); store.dir.failWrite = true;
  await assert.rejects(store.save(payload(1)), /disk full/);
  assert.equal(await (await FolderStore.open(parent)).load(), null);
  store.dir.failWrite = false; await store.save(payload(1));
  assert.equal(await (await FolderStore.open(parent)).load(), payload(1));
});
test('corrupt newest slot falls back with a visible notice; both corrupt refuse startup', async () => {
  const {parent, store} = await setup(); await store.save(payload(1)); await store.save(payload(2));
  await writeText(store.dir, 'checkpoint-1.json', 'broken');
  const recovered = await FolderStore.open(parent); assert.equal(await recovered.load(), payload(1)); assert.ok(recovered.notice);
  await writeText(store.dir, 'checkpoint-0.json', 'broken');
  await assert.rejects((await FolderStore.open(parent)).load(), /손상/);
});
test('valid JSON with an incorrect checksum is rejected', async () => {
  const {parent, store} = await setup(); await store.save(payload(1));
  const value = JSON.parse(await readText(store.dir, 'checkpoint-0.json')); value.payload = payload(9);
  await writeText(store.dir, 'checkpoint-0.json', JSON.stringify(value));
  await assert.rejects((await FolderStore.open(parent)).load(), /손상/);
});
test('newer format never silently falls back to an older checkpoint', async () => {
  const {parent, store} = await setup(); await store.save(payload(1));
  await writeText(store.dir, 'checkpoint-1.json', JSON.stringify({version: 2}));
  await assert.rejects((await FolderStore.open(parent)).load(), /최신/);
});
test('a stale writer cannot overwrite externally advanced data', async () => {
  const {parent, store} = await setup(); await store.save(payload(1));
  const other = await FolderStore.open(parent); await other.load(); await other.save(payload(2));
  await assert.rejects(store.save(payload(3)), /다른 창/);
  assert.equal(await (await FolderStore.open(parent)).load(), payload(2));
});
test('unmarked occupied app folder is not adopted or overwritten', async () => {
  const parent = new Directory(); const dir = await parent.getDirectoryHandle('ChagokLedger', {create: true});
  await writeText(dir, 'personal.txt', 'keep');
  await assert.rejects(FolderStore.open(parent), /식별/); assert.equal(await readText(dir, 'personal.txt'), 'keep');
});
test('device deletion preserves parent files, unknown nested files and owner marker', async () => {
  const {parent, store} = await setup(); await store.save(payload(1));
  await writeText(parent, 'family.xlsx', 'keep'); await writeText(store.dir, 'my-notes.txt', 'keep');
  await store.backup(JSON.stringify({format: 'chagok-backup', version: 1}), 'restore');
  const backups = await store.dir.getDirectoryHandle('backups'); await writeText(backups, 'manual.json', 'keep');
  await writeText(backups, 'before-restore-12345678-1234-1234-1234-123456789abc.json', 'damaged owned backup');
  await store.erase();
  assert.equal(await readText(parent, 'family.xlsx'), 'keep'); assert.equal(await readText(store.dir, 'my-notes.txt'), 'keep');
  assert.equal(await readText(backups, 'manual.json'), 'keep'); assert.equal(backups.entries.size, 1);
  assert.ok(await readText(store.dir, 'owner.json')); assert.equal(await readText(store.dir, 'checkpoint-0.json'), null);
});
test('deletion refuses a changed ownership marker', async () => {
  const {store} = await setup(); await store.save(payload(1));
  await writeText(store.dir, 'owner.json', JSON.stringify({format: 'chagok-folder', id: 'other'}));
  await assert.rejects(store.erase(), /폴더가 변경/); assert.ok(await readText(store.dir, 'checkpoint-0.json'));
});
test('fingerprints cover both slots, including the previous generation', async () => {
  const {store} = await setup(); await store.save(payload(1)); await store.save(payload(2));
  const previous = JSON.parse(await readText(store.dir, 'checkpoint-0.json'));
  previous.payload = payload(8); previous.sha256 = await hash(previous.payload);
  await writeText(store.dir, 'checkpoint-0.json', JSON.stringify(previous));
  await assert.rejects(store.save(payload(3)), /다른 창/);
});
test('file connection exchanges requests without touching checkpoint fingerprints', async () => {
  const {store} = await setup(); await store.save(payload(1));
  const fingerprint = store.fingerprint;
  assert.equal(await store.readConnectionRequest(), null);
  const dir = await store.connectionDirectory();
  await writeText(dir, 'request.json', '{"id":"request-1"}');
  assert.equal(await store.readConnectionRequest(), '{"id":"request-1"}');
  await store.writeConnection('result.json', '{"status":"applied"}');
  assert.equal(await readText(dir, 'result.json'), '{"status":"applied"}');
  assert.equal(store.fingerprint, fingerprint);
  await store.save(payload(2));
  await assert.rejects(store.writeConnection('../checkpoint-0.json', 'bad'), /지원하지/);
});
test('connection refuses to adopt occupied or foreign folders', async () => {
  const {store} = await setup();
  const dir = await store.dir.getDirectoryHandle('codex', {create: true});
  await writeText(dir, 'snapshot.json', 'personal');
  await assert.rejects(store.connectionDirectory(), /기존 파일/);
  await writeText(dir, 'owner.json', JSON.stringify({format:'chagok-file-connection',version:1,owner:'other'}));
  await assert.rejects(store.connectionDirectory(), /다른 가계부/);
  assert.equal(await readText(dir, 'snapshot.json'), 'personal');
});
test('erasing the device also removes connection exports and automatic edit backups', async () => {
  const {store} = await setup(); await store.save(payload(1));
  await store.backup('{}', 'codex');
  await store.writeConnection('snapshot.json', '{"private":"data"}');
  const dir = await store.connectionDirectory();
  await writeText(dir, 'request.json', '{}');
  await store.erase();
  assert.equal(await readText(dir, 'snapshot.json'), null);
  assert.equal(await readText(dir, 'request.json'), null);
  assert.equal(store.dir.entries.has('backups'), false);
});
