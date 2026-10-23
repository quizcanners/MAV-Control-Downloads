import {validName} from '../join/invitation.mjs';
import {readHandoff, handoffFragment, appLink, compatible} from './handoff.mjs';
import {relay} from './configuration.mjs';

const node = id => document.getElementById(id);
let worker, objectUrl, state = 'idle';
let refreshControls;
function release() {
  worker?.terminate(); worker = undefined;
  if (objectUrl) URL.revokeObjectURL(objectUrl);
  objectUrl = undefined;
}
window.addEventListener('pagehide', () => {
  const interrupted = state === 'downloading' || state === 'cancelling' || state === 'ready';
  release();
  if (!interrupted) return;
  state = 'idle';
  node('save').hidden = true; node('save').removeAttribute('href');
  node('cancel').hidden = true;
  node('status').textContent = 'Запрошення збережене. За потреби завантажте інсталятор знову. / Your invitation is retained. Download the installer again if needed.';
  refreshControls?.();
});
window.addEventListener('pageshow', () => refreshControls?.());
window.addEventListener('hashchange', () => { release(); location.reload(); });
try {
  const entry = readHandoff(location.hash), name = node('name'), open = node('open');
  const supported = compatible(entry.descriptor.platform, navigator.userAgent);
  const label = entry.descriptor.platform === 'android-arm64' ? 'Android ARM64' : 'Windows x64';
  node('inviter').textContent = 'Запрошує / Invited by: ' + entry.inviter;
  node('package').textContent = label + ' · ' + entry.descriptor.division + ' · ' + entry.descriptor.channel + ' · ' + entry.descriptor.version;
  node('journey').hidden = false;
  if (!supported) node('platformIssue').textContent = 'Інсталятор призначений для ' + label + '. Відкрийте цю сторінку на тому пристрої. / This installer requires ' + label + '. Open this page on that device.';
  name.value = entry.name;
  function refresh() {
    const value = name.value.trim(), okay = validName(value);
    open.setAttribute('aria-disabled', String(!okay));
    if (okay) open.href = appLink(entry, value); else open.removeAttribute('href');
    history.replaceState(null, '', location.pathname + handoffFragment(entry, value));
    node('nameIssue').textContent = okay ? '' : 'Введіть ім’я щонайменше з 5 символів / Enter a name of at least 5 characters';
    node('prepare').disabled = !okay || !supported || state === 'downloading' || state === 'cancelling';
  }
  refreshControls = refresh;
  name.addEventListener('input', refresh);
  node('cancel').addEventListener('click', () => {
    if (state !== 'downloading') return;
    state = 'cancelling'; worker.postMessage({type: 'cancel'});
    node('cancel').disabled = true;
    node('status').textContent = 'Скасовуємо / Cancelling…';
  });
  node('prepare').addEventListener('click', () => {
    if (!validName(name.value.trim()) || !supported || state === 'downloading' || state === 'cancelling') return;
    release(); state = 'downloading'; node('save').hidden = true; node('save').removeAttribute('href');
    node('cancel').hidden = false; node('cancel').disabled = false;
    node('status').textContent = 'Завантажуємо та перевіряємо / Downloading and verifying…'; refresh();
    function fail(code) {
      release(); state = 'failed'; node('cancel').hidden = true;
      node('status').textContent = code === 'cancelled' ? 'Скасовано. Запрошення збережене. / Cancelled. Your invitation is retained.'
        : 'Не вдалося перевірити інсталятор. Повторіть спробу або попросіть нове посилання. / The installer could not be verified. Retry or ask the inviter for a new link.';
      refresh();
    }
    try {
      worker = new Worker('./download-worker.mjs', {type: 'module'});
      worker.onerror = () => fail('worker');
      worker.onmessage = event => {
        const data = event.data;
        if (data?.type === 'progress' && state === 'downloading') {
          node('status').textContent = 'Завантажуємо та перевіряємо / Downloading and verifying: '
            + Math.min(100, Math.floor(100 * data.received / entry.descriptor.size)) + '%';
        } else if (data?.type === 'ready' && state === 'downloading' && data.file instanceof Blob
            && data.file.size === entry.descriptor.size - 56) {
          objectUrl = URL.createObjectURL(data.file); state = 'ready';
          const save = node('save'); save.href = objectUrl; save.download = entry.descriptor.filename; save.hidden = false;
          node('cancel').hidden = true;
          node('status').textContent = 'Інсталятор перевірено. Збережіть і встановіть його, потім поверніться сюди. / Installer verified. Save and install it, then return here.';
          refresh(); // Keep the prepared file's exclusive owner until this page releases its Save URL.
        } else if (data?.type === 'error') fail(data.code);
        else if (data?.type === 'ready') fail(state === 'cancelling' ? 'cancelled' : 'integrity');
      };
      const key = entry.key.slice().buffer;
      worker.postMessage({descriptor: entry.descriptor, key, url: relay + entry.descriptor.sha256}, [key]);
    } catch { fail('worker'); }
  });
  refresh();
} catch {
  release(); node('journey').hidden = true;
  node('inviter').textContent = 'Недійсне посилання. Попросіть новий QR-код. / Invalid installation link. Ask for a new QR code.';
}
