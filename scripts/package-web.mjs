import {readdir, readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';

const root = path.resolve('build/web');
async function files(dir) {
  const result = [];
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...await files(full));
    else result.push(full);
  }
  return result;
}
const list = (await files(root)).map(file => path.relative(root, file).replaceAll('\\', '/'))
  .filter(file => !['sw.js', 'flutter_service_worker.js', '.last_build_id'].includes(file) && !file.endsWith('.map')).sort();
const hash = createHash('sha256');
for (const file of list) { hash.update(file); hash.update(await readFile(path.join(root, file))); }
const version = hash.digest('hex').slice(0, 24);
const template = await readFile('web/sw-template.js', 'utf8');
await writeFile(path.join(root, 'sw.js'), template.replace('__VERSION__', version).replace('__FILES__', JSON.stringify(list)));
await writeFile(path.join(root, '.nojekyll'), '');
console.log(`Packaged offline web app ${version} (${list.length} static files).`);
