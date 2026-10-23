import { sha256 } from './vendor/noble-hashes/sha2.js';
import { hmac } from './vendor/noble-hashes/hmac.js';

const BLOCK = 1024 * 1024;
const text = new TextEncoder();
export class UnsealError extends Error {
  constructor(code) { super(code); this.name = 'UnsealError'; this.code = code; }
}
const fail = code => { throw new UnsealError(code); };
const equal = (a, b) => {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
};
const hex = bytes => Array.from(bytes, x => x.toString(16).padStart(2, '0')).join('');

// The sink is PRIVATE staging: authentication happens only after the last ciphertext byte.
// This function creates no File, URL or download and never retains the complete package.
export async function unseal(stream, descriptor, keyBytes, sink, signal, progress) {
  if (!descriptor || !Number.isSafeInteger(descriptor.size) || descriptor.size < 57 || descriptor.size >= 2 ** 31
      || typeof descriptor.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(descriptor.sha256)
      || typeof descriptor.filename !== 'string' || descriptor.filename.length < 1 || descriptor.filename.length > 160
      || !['android-arm64', 'windows-x64'].includes(descriptor.platform)) fail('descriptor');
  if (!(keyBytes instanceof Uint8Array) || keyBytes.length !== 32) fail('key');
  if (!stream || typeof stream.getReader !== 'function' || !sink || typeof sink.write !== 'function') fail('source');
  if (!globalThis.crypto?.subtle) fail('unsupported');
  const size = descriptor.size, expectedHash = descriptor.sha256.toLowerCase();
  const cancelled = () => { if (signal?.aborted) fail('cancelled'); };
  cancelled();
  const key = keyBytes.slice(), enc = hmac(sha256, key, text.encode('mav-seal-enc'));
  const macKey = hmac(sha256, key, text.encode('mav-seal-mac'));
  const identity = sha256.create().update(text.encode('mav-seal-id')).update(key).digest().slice(0, 4);
  const auth = hmac.create(sha256, macKey), digest = sha256.create();
  const header = new Uint8Array(24), tag = new Uint8Array(32), buffer = new Uint8Array(BLOCK);
  const reader = stream.getReader();
  const abort = () => { reader.cancel().catch(() => {}); };
  signal?.addEventListener('abort', abort, { once: true });
  let received = 0, written = 0, buffered = 0, cipherReceived = 0, tagReceived = 0, authenticated = false;
  const cipherSize = size - 56;
  let aes;
  async function decryptBuffered() {
    if (!buffered) return;
    cancelled();
    const counter = new Uint8Array(16);
    counter.set(header.subarray(12, 24));
    new DataView(counter.buffer).setUint32(12, written / 16, false);
    let plaintext;
    try {
      plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-CTR', counter, length: 32 }, aes, buffer.subarray(0, buffered)));
      cancelled();
      try { await sink.write(plaintext); } catch { fail('storage'); }
      written += buffered;
    } catch (error) {
      if (error instanceof UnsealError) throw error;
      fail('integrity');
    } finally { plaintext?.fill(0); buffer.fill(0, 0, buffered); buffered = 0; }
  }
  try {
    aes = await crypto.subtle.importKey('raw', enc, 'AES-CTR', false, ['decrypt']);
    for (;;) {
      cancelled();
      let next;
      try { next = await reader.read(); } catch { cancelled(); fail('source'); }
      cancelled();
      if (next.done) break;
      const bytes = next.value;
      if (!(bytes instanceof Uint8Array)) fail('source');
      if (bytes.length > size - received) fail('integrity');
      digest.update(bytes);
      let at = 0;
      if (received < header.length) {
        const count = Math.min(bytes.length, header.length - received);
        header.set(bytes.subarray(0, count), received); received += count; at += count;
        if (received === header.length) {
          if (!equal(header.subarray(0, 8), text.encode('MAVSEAL1'))) fail('header');
          if (!equal(header.subarray(8, 12), identity)) fail('key');
          auth.update(header);
        }
      }
      while (at < bytes.length && cipherReceived < cipherSize) {
        const count = Math.min(bytes.length - at, cipherSize - cipherReceived, BLOCK - buffered);
        const part = bytes.subarray(at, at + count);
        auth.update(part); buffer.set(part, buffered);
        at += count; received += count; cipherReceived += count; buffered += count;
        if (buffered === BLOCK || cipherReceived === cipherSize) await decryptBuffered();
      }
      if (at < bytes.length) {
        const part = bytes.subarray(at);
        if (part.length > tag.length - tagReceived) fail('integrity');
        tag.set(part, tagReceived); tagReceived += part.length; received += part.length;
      }
      if (progress) progress({ received, total: size });
    }
    if (received !== size || cipherReceived !== cipherSize || tagReceived !== tag.length || written !== cipherSize) fail('integrity');
    if (!equal(auth.digest(), tag) || hex(digest.digest()) !== expectedHash) fail('integrity');
    cancelled();
    authenticated = true;
    return { received, written };
  } finally {
    signal?.removeEventListener('abort', abort);
    if (!authenticated) { try { await reader.cancel(); } catch {} }
    reader.releaseLock();
    key.fill(0); enc.fill(0); macKey.fill(0); identity.fill(0); header.fill(0); tag.fill(0); buffer.fill(0);
    auth.destroy(); digest.destroy();
  }
}
