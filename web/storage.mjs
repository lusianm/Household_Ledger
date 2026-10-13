// No browser globals: the same file is exercised with fault-injecting file handles.
const slots = ['checkpoint-0.json', 'checkpoint-1.json'];
const missing = e => e?.name === 'NotFoundError';
export async function readText(dir, name) {
  try { return await (await (await dir.getFileHandle(name)).getFile()).text(); }
  catch (e) { if (missing(e)) return null; throw e; }
}
export async function writeText(dir, name, text) {
  const writer = await (await dir.getFileHandle(name, {create: true})).createWritable();
  try { await writer.write(text); await writer.close(); }
  catch (e) { await writer.abort().catch(() => {}); throw e; }
}
export async function hash(text) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(bytes)].map(n => n.toString(16).padStart(2, '0')).join('');
}
export class FolderStore {
  constructor(dir, owner) { this.dir = dir; this.owner = owner; this.generation = 0; this.fingerprint = null; this.notice = ''; }
  static async open(parent) {
    const dir = await parent.getDirectoryHandle('ChagokLedger', {create: true});
    let marker = await readText(dir, 'owner.json');
    if (marker === null) {
      for await (const _ of dir.values()) {
        throw new Error('ChagokLedger 폴더에 식별할 수 없는 파일이 있습니다. 다른 폴더를 선택해 주세요.');
      }
      marker = JSON.stringify({format: 'chagok-folder', version: 1, id: crypto.randomUUID()});
      await writeText(dir, 'owner.json', marker);
    }
    const owner = JSON.parse(marker);
    if (owner.format !== 'chagok-folder' || owner.version !== 1 || typeof owner.id !== 'string') {
      throw new Error('앱 폴더 식별자가 올바르지 않습니다. 기존 파일은 변경하지 않았습니다.');
    }
    return new FolderStore(dir, owner);
  }
  async inspect() {
    const raw = await Promise.all(slots.map(name => readText(this.dir, name)));
    const valid = []; let damaged = 0;
    for (let slot = 0; slot < raw.length; slot++) {
      if (raw[slot] === null) continue;
      let envelope;
      try { envelope = JSON.parse(raw[slot]); } catch { damaged++; continue; }
      if (envelope.version > 1) throw new Error('더 최신 앱에서 만든 파일입니다. 앱을 업데이트해 주세요.');
      if (envelope.format !== 'chagok-checkpoint' || envelope.version !== 1 ||
          !Number.isSafeInteger(envelope.generation) || envelope.generation < 1 ||
          typeof envelope.payload !== 'string' || envelope.sha256 !== await hash(envelope.payload)) {
        damaged++; continue;
      }
      try {
        const data = JSON.parse(envelope.payload);
        if (data.format !== 'chagok-device' || data.version !== 1) throw new Error();
      } catch { damaged++; continue; }
      valid.push({...envelope, slot});
    }
    if (damaged && !valid.length) throw new Error('저장 파일이 손상되었습니다. 새 가계부로 덮어쓰지 않았습니다. 백업을 별도 폴더에서 복원해 주세요.');
    valid.sort((a, b) => b.generation - a.generation);
    if (valid.length === 2 && valid[0].generation === valid[1].generation) throw new Error('중복된 저장 세대입니다. 파일을 확인해 주세요.');
    return {latest: valid[0] ?? null, damaged, fingerprint: await hash(JSON.stringify(raw))};
  }
  async load() {
    const state = await this.inspect();
    this.generation = state.latest?.generation ?? 0;
    this.slot = state.latest?.slot ?? 1;
    this.fingerprint = state.fingerprint;
    if (state.damaged) this.notice = '손상된 파일을 제외하고 마지막 정상 저장본을 열었습니다. 최근 내역을 확인하고 Drive 동기화 또는 백업으로 복구해 주세요.';
    return state.latest?.payload ?? null;
  }
  async verify() {
    const owner = JSON.parse(await readText(this.dir, 'owner.json'));
    if (owner?.id !== this.owner.id || owner.format !== 'chagok-folder' || owner.version !== 1) throw new Error('저장 폴더가 변경되어 작업을 중지했습니다.');
    if ((await this.inspect()).fingerprint !== this.fingerprint) throw new Error('다른 창이나 프로그램에서 파일이 변경되었습니다. 전체 백업을 내보낸 뒤 다시 열어 주세요.');
  }
  async save(payload) {
    await this.verify();
    const envelope = {format: 'chagok-checkpoint', version: 1, generation: this.generation + 1, payload, sha256: await hash(payload)};
    const next = 1 - this.slot;
    const before = await Promise.all(slots.map(name => readText(this.dir, name)));
    try { await writeText(this.dir, slots[next], JSON.stringify(envelope)); }
    catch (error) {
      // Creating a brand-new file can leave an empty placeholder even if close
      // fails. Remove only that exact placeholder, never an existing checkpoint.
      const after = await Promise.all(slots.map(name => readText(this.dir, name)));
      if (before[next] === null && after[next] === '' && after[1-next] === before[1-next]) {
        await this.dir.removeEntry(slots[next]);
      }
      throw error;
    }
    // Read back before acknowledging a save; the older valid slot remains intact.
    const state = await this.inspect();
    if (state.latest?.sha256 !== envelope.sha256 || state.latest.generation !== envelope.generation) throw new Error('저장 결과를 확인하지 못했습니다.');
    this.slot = next; this.generation = envelope.generation; this.fingerprint = state.fingerprint;
  }
  async backup(payload, purpose) {
    await this.verify();
    const dir = await this.dir.getDirectoryHandle('backups', {create: true});
    const name = `before-${purpose}-${crypto.randomUUID()}.json`;
    await writeText(dir, name, payload);
    return `ChagokLedger/backups/${name}`;
  }
  async erase() {
    await this.verify();
    // Never recursively delete the user's selected parent or unknown files.
    try {
      const backups = await this.dir.getDirectoryHandle('backups');
      for await (const entry of backups.values()) {
        if (entry.kind !== 'file' || !/^before-(restore|update)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$/.test(entry.name)) continue;
        // Owned backup filenames remain deletable even if their contents are damaged.
        await backups.removeEntry(entry.name);
      }
      try { await this.dir.removeEntry('backups'); } catch (e) { if (e.name !== 'InvalidModificationError') throw e; }
    } catch (e) { if (!missing(e)) throw e; }
    for (const name of slots) {
      try { await this.dir.removeEntry(name); } catch (e) { if (!missing(e)) throw e; }
    }
    // Marker is retained so unrelated files left in this directory stay untouched.
    this.fingerprint = (await this.inspect()).fingerprint;
  }
}
