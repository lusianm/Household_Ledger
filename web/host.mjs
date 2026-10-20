import {FolderStore} from './storage.mjs';

const base = new URL('./', document.baseURI);
const namespace = `chagok:${base.pathname}`;
const status = document.querySelector('#status');
const choose = document.querySelector('#choose');
const reconnect = document.querySelector('#reconnect');
choose.disabled = true;
let folder, remembered, checkpoint = null, dirty = false, booted = false, installPrompt;
const tokenKey = `${namespace}:google-token`;
const text = message => { status.textContent = message; };
const idb = new Promise((resolve, reject) => {
  const request = indexedDB.open(namespace, 1);
  request.onupgradeneeded = () => request.result.createObjectStore('preferences');
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});
async function preference(write, value) {
  const db = await idb;
  return new Promise((resolve, reject) => {
    const tx = db.transaction('preferences', write ? 'readwrite' : 'readonly');
    const store = tx.objectStore('preferences');
    const request = write ? (value ? store.put(value, 'folder') : store.delete('folder')) : store.get('folder');
    tx.oncomplete = () => resolve(request.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}
function readToken() {
  try { return JSON.parse(sessionStorage.getItem(tokenKey)); } catch { return null; }
}
let pendingToken = false;
let accountHint = '';
window.chagok = {
  read: () => checkpoint,
  info: () => JSON.stringify({folder: `${remembered?.name ?? ''}/ChagokLedger`, notice: folder?.notice ?? ''}),
  markDirty: () => { dirty = true; },
  save: async payload => { await folder.save(payload); checkpoint = payload; dirty = false; },
  backup: (payload, purpose) => folder.backup(payload, purpose),
  readConnectionRequest: () => folder.readConnectionRequest(),
  writeConnection: (name, payload) => folder.writeConnection(name, payload),
  erase: async () => {
    await folder.erase();
    await preference(true, null);
    sessionStorage.removeItem(tokenKey);
    dirty = false;
    location.reload();
  },
  hint: value => { accountHint = value; },
  disconnect: async () => { sessionStorage.removeItem(tokenKey); accountHint = ''; },
  token: (clientId, interactive, refresh) => {
    const cached = readToken();
    if (!refresh && cached?.clientId === clientId && cached.expires > Date.now() + 60000) return Promise.resolve(cached.accessToken);
    sessionStorage.removeItem(tokenKey);
    if (!interactive) return Promise.reject(new Error('Google 연결이 필요해요. 동기화 버튼을 눌러 주세요.'));
    if (!clientId) return Promise.reject(new Error('배포 설정에 GOOGLE_WEB_CLIENT_ID가 필요합니다. 로컬 가계부는 계속 사용할 수 있어요.'));
    if (!globalThis.google?.accounts?.oauth2) return Promise.reject(new Error('Google 인증을 불러오지 못했어요. 인터넷 연결 후 다시 눌러 주세요.'));
    if (pendingToken) return Promise.reject(new Error('열린 Google 인증 창을 먼저 확인해 주세요.'));
    pendingToken = true;
    return new Promise((resolve, reject) => {
      let finished = false;
      const finish = (error, response) => {
        if (finished) return;
        finished = true; pendingToken = false; clearTimeout(timeout);
        if (error) { reject(new Error(error)); return; }
        sessionStorage.setItem(tokenKey, JSON.stringify({clientId, accessToken: response.access_token, expires: Date.now() + Number(response.expires_in) * 1000}));
        resolve(response.access_token);
      };
      const timeout = setTimeout(() => finish('Google 인증 시간이 지났어요. 다시 눌러 주세요.'), 120000);
      try {
        google.accounts.oauth2.initTokenClient({
          client_id: clientId, scope: 'https://www.googleapis.com/auth/drive',
          prompt: accountHint ? '' : 'select_account', login_hint: accountHint,
          callback: response => {
            if (response.error || !response.access_token || !Number.isFinite(Number(response.expires_in))) finish('Google Drive 접근을 승인해 주세요.');
            else finish(null, response);
          },
          error_callback: () => finish('Google 인증 창을 닫았거나 브라우저가 차단했습니다. 동기화 버튼을 다시 눌러 주세요.'),
        }).requestAccessToken();
      } catch (e) { finish(e.message); }
    });
  },
  install: async () => {
    if (!installPrompt) return '브라우저 메뉴의 앱 설치 또는 홈 화면에 추가를 사용해 주세요.';
    await installPrompt.prompt();
    const result = await installPrompt.userChoice; installPrompt = null;
    return result.outcome === 'accepted' ? '앱 설치를 요청했어요.' : '설치를 취소했어요.';
  },
  checkUpdate: async () => {
    if (!registration) throw new Error('서비스 워커를 준비하지 못했어요. 온라인으로 앱을 다시 열어 주세요.');
    await registration.update();
    if (registration.installing) {
      const worker = registration.installing;
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('업데이트 다운로드가 지연되고 있어요. 잠시 뒤 다시 확인해 주세요.')), 30000);
        const check = () => {
          if (worker.state === 'installed' || worker.state === 'redundant') { clearTimeout(timer); resolve(); }
        };
        worker.addEventListener('statechange', check); check();
      });
    }
    return Boolean(registration.waiting);
  },
  applyUpdate: async () => {
    if (dirty) throw new Error('기기에 저장한 다음 업데이트해 주세요.');
    if (!registration?.waiting) return;
    navigator.serviceWorker.addEventListener('controllerchange', () => location.reload(), {once: true});
    registration.waiting.postMessage('activate');
  },
};
window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
window.addEventListener('flutter-first-frame', () => document.querySelector('#gate')?.remove(), {once: true});
window.addEventListener('beforeinstallprompt', event => { event.preventDefault(); installPrompt = event; });
// Auth/Drive requests are never stored in the service worker cache.
const authScript = document.createElement('script');
authScript.src = 'https://accounts.google.com/gsi/client'; authScript.async = true;
document.head.append(authScript);
let registration;
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register(new URL('sw.js', base), {scope: base.pathname, updateViaCache: 'none'})
    .then(value => { registration = value; }).catch(() => {});
}
async function open(parent) {
  choose.disabled = true; reconnect.disabled = true;
  try {
    folder = await FolderStore.open(parent);
    checkpoint = await folder.load();
    await preference(true, parent); remembered = parent;
    text('저장 폴더를 열었습니다. 가계부를 준비하고 있어요…');
    if (!booted) {
      booted = true;
      const script = document.createElement('script'); script.src = new URL('flutter_bootstrap.js', base);
      script.onerror = () => text('앱을 불러오지 못했습니다. 인터넷 연결 후 다시 열어 주세요.');
      document.body.append(script);
    }
  } catch (e) { text(e.message); choose.disabled = false; reconnect.disabled = false; }
}
choose.onclick = async () => {
  try { const parent = await window.showDirectoryPicker({id: 'chagok-local', mode: 'readwrite', startIn: 'documents'}); await open(parent); }
  catch (e) { if (e.name !== 'AbortError') text(e.message); }
};
reconnect.onclick = async () => {
  try {
    if (await remembered.requestPermission({mode: 'readwrite'}) !== 'granted') throw new Error('가계부 폴더의 읽기·쓰기 권한이 필요합니다.');
    await open(remembered);
  } catch (e) { text(e.message); }
};
async function start() {
  if (!isSecureContext || !window.showDirectoryPicker || !navigator.locks) {
    choose.disabled = true;
    text('이 브라우저에서는 폴더 저장을 지원하지 않습니다. 최신 Android Chrome 또는 Windows Chrome/Edge에서 HTTPS 주소로 열어 주세요.');
    return;
  }
  await navigator.locks.request(namespace, {ifAvailable: true}, async lock => {
    if (!lock) { choose.disabled = true; text('다른 창에서 차곡을 사용 중입니다. 그 창을 닫고 다시 열어 주세요.'); return; }
    choose.disabled = false;
    try {
      remembered = await preference(false);
      if (remembered) {
        reconnect.hidden = false;
        if (await remembered.queryPermission({mode: 'readwrite'}) === 'granted') await open(remembered);
        else text('이전에 사용한 폴더의 접근 권한을 다시 허용해 주세요.');
      } else text('시작하려면 기기의 저장 폴더를 선택해 주세요.');
    } catch (e) { text(`폴더 연결 정보를 읽지 못했습니다. 기존 폴더를 다시 선택해 주세요. ${e.message}`); }
    await new Promise(() => {}); // Released by the browser when this document closes.
  });
}
start().catch(e => text(e.message));
