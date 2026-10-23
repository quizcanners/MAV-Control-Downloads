import { unseal, UnsealError } from './unseal.mjs';
import { relay } from './configuration.mjs';

const requestOptions = signal => ({ method: 'GET', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer', signal });

async function admitCatalog(descriptor, signal) {
  let response;
  try { response = await fetch(relay + 'catalog', requestOptions(signal)); }
  catch { throw new UnsealError('catalog'); }
  if (!response.ok || !response.body) throw new UnsealError('catalog');
  const limit = 1024 * 1024, bytes = new Uint8Array(limit), reader = response.body.getReader();
  let used = 0, complete = false, catalog;
  try {
    for (;;) {
      const next = await reader.read();
      if (signal.aborted) throw new UnsealError('cancelled');
      if (next.done) break;
      if (!(next.value instanceof Uint8Array) || next.value.length > limit - used) throw new UnsealError('catalog');
      bytes.set(next.value, used); used += next.value.length;
    }
    catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, used)));
    complete = true;
  } catch (error) {
    if (error instanceof UnsealError) throw error;
    throw new UnsealError('catalog');
  } finally {
    if (!complete) { try { await reader.cancel(); } catch {} }
    reader.releaseLock();
  }
  if (!catalog || catalog.schema !== 1 || !Array.isArray(catalog.packages) || !Array.isArray(catalog.ios)
      || catalog.packages.length + catalog.ios.length > 512) throw new UnsealError('catalog');
  let match = null;
  for (const row of catalog.packages) {
    if (!row || typeof row !== 'object' || typeof row.sha256 !== 'string' || typeof row.source !== 'string') throw new UnsealError('catalog');
    const same = row.platform === descriptor.platform && row.filename === descriptor.filename && row.size === descriptor.size
      && row.sha256.toLowerCase() === descriptor.sha256.toLowerCase() && row.division === descriptor.division
      && row.channel === descriptor.channel && row.version === descriptor.version && row.source.toLowerCase() === descriptor.source.toLowerCase();
    if (!same) continue;
    // Identical duplicate rows are harmless; conflicting metadata under this exact release identity is not.
    if (match && (match.url !== row.url || match.published_at !== row.published_at)) throw new UnsealError('catalog');
    match = row;
  }
  if (!match) throw new UnsealError('identity');
}

let active = null;
let preparedAccess = null;
self.onmessage = event => {
  const message = event.data;
  if (message?.type === 'cancel') { active?.abort('cancelled'); return; }
  if (active || preparedAccess) {
    if (message?.key instanceof ArrayBuffer) new Uint8Array(message.key).fill(0);
    self.postMessage({ type: 'error', code: 'busy' });
    return;
  }
  const controller = new AbortController();
  active = controller;
  const deadline = setTimeout(() => controller.abort('deadline'), 180000);
  run(message, controller).finally(() => { clearTimeout(deadline); active = null; });
};

async function run(message, controller) {
  let handle, access, success = false;
  const key = message?.key instanceof ArrayBuffer ? new Uint8Array(message.key) : null;
  try {
    if (!navigator.storage?.getDirectory) throw new UnsealError('unsupported');
    if (!key) throw new UnsealError('key');
    if (key.length !== 32) throw new UnsealError('key');
    const descriptor = message.descriptor;
    if (!descriptor || typeof descriptor.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(descriptor.sha256)
        || typeof descriptor.source !== 'string' || !/^[a-f0-9]{40}$/i.test(descriptor.source)
        || !Number.isSafeInteger(descriptor.size) || descriptor.size < 57 || descriptor.size >= 2 ** 31
        || !Number.isSafeInteger(descriptor.version) || descriptor.version < 1
        || !['stable', 'test'].includes(descriptor.channel) || typeof descriptor.division !== 'string'
        || typeof descriptor.filename !== 'string' || !['android-arm64', 'windows-x64'].includes(descriptor.platform)) throw new UnsealError('descriptor');
    if (message.url !== relay + descriptor.sha256) throw new UnsealError('source');
    const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle('mav-control-installer', { create: true });
    handle = await directory.getFileHandle('pending', { create: true });
    // The default readwrite mode is exclusive. Another tab/worker must fail busy, not queue ownership.
    try { access = await handle.createSyncAccessHandle(); }
    catch (error) { throw new UnsealError(error?.name === 'NoModificationAllowedError' ? 'busy' : 'storage'); }
    await admitCatalog(descriptor, controller.signal);
    access.truncate(0); // Explicit new start may replace only this owner's fixed private pending file.
    let position = 0;
    const sink = { write(bytes) {
      let at = 0;
      while (at < bytes.length) {
        const count = access.write(bytes.subarray(at), { at: position });
        if (!Number.isInteger(count) || count <= 0 || count > bytes.length - at) throw new UnsealError('storage');
        at += count; position += count;
      }
    } };
    const response = await fetch(relay + descriptor.sha256, requestOptions(controller.signal));
    if (!response.ok || !response.body) throw new UnsealError('source');
    await unseal(response.body, descriptor, key, sink, controller.signal,
      value => self.postMessage({ type: 'progress', received: value.received, total: value.total }));
    if (controller.signal.aborted) throw new UnsealError('cancelled');
    access.flush();
    const file = await handle.getFile();
    if (controller.signal.aborted) throw new UnsealError('cancelled');
    // Only the authenticated completed private file becomes visible to the page.
    // Keep its exclusive handle while Save is available: another tab must not overwrite its backing file.
    self.postMessage({ type: 'ready', file });
    preparedAccess = access; access = null;
    success = true;
  } catch (error) {
    const codes = ['descriptor', 'key', 'header', 'integrity', 'source', 'storage', 'cancelled', 'unsupported', 'busy', 'catalog', 'identity'];
    const code = controller.signal.aborted ? (controller.signal.reason === 'deadline' ? 'deadline' : 'cancelled')
      : error instanceof UnsealError && codes.includes(error.code) ? error.code : 'storage';
    self.postMessage({ type: 'error', code });
  } finally {
    key?.fill(0);
    if (access) {
      try { if (!success) { access.truncate(0); access.flush(); } } catch {}
      try { access.close(); } catch {}
    }
  }
}
