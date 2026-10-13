import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {deflateSync} from 'node:zlib';

await mkdir('web', {recursive: true});
const expected = 'fbcd2e8214f9231ea961e1b7706a22dd1194cfbfe6f26f13841b5aa7a0be1a1f';
let wasm;
try { wasm = await readFile('web/sqlite3.wasm'); } catch {}
if (!wasm || createHash('sha256').update(wasm).digest('hex') !== expected) {
  const response = await fetch('https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.7.0/sqlite3.wasm');
  if (!response.ok) throw new Error(`SQLite WASM download failed: ${response.status}`);
  wasm = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(wasm).digest('hex') !== expected) throw new Error('SQLite WASM checksum mismatch');
  await writeFile('web/sqlite3.wasm', wasm);
}
await mkdir('test', {recursive: true});
await writeFile('test/sqlite3.wasm', wasm);

// Deterministic app icons, generated without a graphics dependency.
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let n = 0; n < 8; n++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]); const size = Buffer.alloc(4), crc = Buffer.alloc(4);
  size.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(body)); return Buffer.concat([size, body, crc]);
}
for (const size of [192, 512]) {
  const pixels = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const u = x / size, v = y / size;
    let color = [0, 155, 196];
    if (u > .25 && u < .75 && v > .28 && v < .75) color = [255, 255, 255];
    if (u > .33 && u < .67 && ((v > .44 && v < .49) || (v > .58 && v < .63))) color = [0, 127, 166];
    const offset = y * (size * 4 + 1) + 1 + x * 4;
    pixels.set([...color, 255], offset);
  }
  const header = Buffer.alloc(13); header.writeUInt32BE(size); header.writeUInt32BE(size, 4); header[8] = 8; header[9] = 6;
  await writeFile(`web/icon-${size}.png`, Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]));
}
console.log('Verified SQLite WASM 3.7.0 and prepared PWA icons.');
