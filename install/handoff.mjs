import {readInvitation, validName, openLink} from '../join/invitation.mjs';

const fields = ['invite', 'name', 'build', 'platform', 'file', 'size', 'sha256'];
const encoder = new TextEncoder();

export function readHandoff(fragment) {
  if (typeof fragment !== 'string' || fragment.length > 4096) throw Error('Invalid installation link');
  const values = new Map();
  for (const pair of fragment.replace(/^#/, '').split('&')) {
    const equals = pair.indexOf('=');
    const field = pair.slice(0, equals);
    if (equals < 1 || !fields.includes(field) || values.has(field)) throw Error('Invalid installation link');
    values.set(field, decodeURIComponent(pair.slice(equals + 1).replace(/\+/g, ' ')));
  }
  for (const field of fields) if (field !== 'name' && !values.has(field)) throw Error('Incomplete installation link');
  const entry = readInvitation('#invite=' + encodeURIComponent(values.get('invite'))
    + (values.has('name') ? '&name=' + encodeURIComponent(values.get('name')) : ''));
  const build = values.get('build');
  if (!build.startsWith('mavkey:1|')) throw Error('Invalid build identity');
  const parts = build.slice('mavkey:1|'.length).split('|');
  if (parts.length !== 5 || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/.test(parts[0])
      || !['test', 'stable'].includes(parts[1]) || !/^[1-9][0-9]{0,9}$/.test(parts[2])
      || Number(parts[2]) > 2147483647 || !/^[a-f0-9]{40}$/.test(parts[3])
      || !/^[A-Za-z0-9+/]{43}=$/.test(parts[4])) throw Error('Invalid build identity');
  const key = Uint8Array.from(atob(parts[4]), c => c.charCodeAt(0));
  if (key.length !== 32 || btoa(String.fromCharCode(...key)) !== parts[4]) throw Error('Invalid build key');
  const platform = values.get('platform'), filename = values.get('file'), sizeText = values.get('size');
  const sha256 = values.get('sha256');
  if (!['android-arm64', 'windows-x64'].includes(platform)
      || !/^[A-Za-z0-9][A-Za-z0-9._ -]{0,159}$/.test(filename)
      || !filename.toLowerCase().endsWith(platform === 'android-arm64' ? '.apk' : '.exe')
      || !/^[1-9][0-9]{0,9}$/.test(sizeText) || Number(sizeText) < 57 || Number(sizeText) >= 2147483648
      || !/^[a-fA-F0-9]{64}$/.test(sha256)) throw Error('Invalid installer identity');
  // Re-encoding is canonical and must retain the same small envelope, including Unicode names.
  if (encoder.encode(fragment).length > 4096) throw Error('Installation link exceeds its limit');
  return {...entry, descriptor: {platform, filename, size: Number(sizeText), sha256: sha256.toLowerCase(),
    division: parts[0], channel: parts[1], version: Number(parts[2]), source: parts[3]}, key, build};
}

export function handoffFragment(entry, name) {
  const values = {invite: entry.invitation, ...(validName(name) ? {name} : {}), build: entry.build,
    platform: entry.descriptor.platform, file: entry.descriptor.filename, size: String(entry.descriptor.size), sha256: entry.descriptor.sha256};
  const fragment = '#' + Object.entries(values).map(([key, value]) => key + '=' + encodeURIComponent(value)).join('&');
  readHandoff(fragment);
  return fragment;
}

export function appLink(entry, name) {
  // Package capability stays in the browser. The installed app receives only the existing named invitation.
  return openLink(entry.invitation, name);
}

export function compatible(platform, userAgent) {
  return platform === 'android-arm64' ? /Android/i.test(userAgent)
    : platform === 'windows-x64' && /Windows NT/i.test(userAgent) && !/Android/i.test(userAgent);
}
