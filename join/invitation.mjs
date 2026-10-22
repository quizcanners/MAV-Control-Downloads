// Keep credentials in the fragment. Opening/previewing this page never redeems
// an invitation or grants authentication; the app uses its own keys and server.
export function validName(name) {
  if (typeof name !== 'string' || !name || name !== name.trim() || /[\p{Cc}|]/u.test(name)
      || new TextEncoder().encode(name).length > 64) return false;
  return [...new Intl.Segmenter(undefined, {granularity: 'grapheme'}).segment(name)].length >= 5;
}

function key(text, length) {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return false;
  try { return atob(text).length === length; } catch { return false; }
}

function address(text) {
  const parts = text.split('.');
  return parts.length === 4 && parts.every(p => /^(0|[1-9][0-9]{0,2})$/.test(p) && Number(p) <= 255);
}

export function readInvitation(fragment) {
  if (typeof fragment !== 'string' || fragment.length > 4096) throw Error('Invalid invitation');
  const fields = new Map();
  for (const pair of fragment.replace(/^#/, '').split('&')) {
    const equals = pair.indexOf('=');
    if (equals < 1) throw Error('Invalid invitation');
    const name = pair.slice(0, equals);
    if (!['invite', 'name'].includes(name) || fields.has(name)) throw Error('Invalid invitation');
    fields.set(name, decodeURIComponent(pair.slice(equals + 1).replace(/\+/g, ' ')));
  }
  const invitation = fields.get('invite');
  if (!invitation?.startsWith('mav-join:1|')) throw Error('Invalid invitation');
  const parts = invitation.slice('mav-join:1|'.length).trim().split('|');
  if (parts.length !== 10 || !parts[0].trim() || /[\u0000-\u001f\u007f]/u.test(parts[0])
      || new TextEncoder().encode(parts[0]).length > 64 || !address(parts[1])
      || !key(parts[2], 32) || !key(parts[3], 32) || !key(parts[4], 8)
      || !address(parts[6]) || !key(parts[7], 32) || !key(parts[8], 32) || !address(parts[9]))
    throw Error('Invalid invitation');
  const name = fields.get('name')?.trim() ?? '';
  return {invitation, inviter: parts[0], name};
}

export function invitationFragment(invitation, name) {
  if (!validName(name)) throw Error('Name needs at least five characters');
  const result = '#invite=' + encodeURIComponent(invitation) + '&name=' + encodeURIComponent(name);
  readInvitation(result);
  if (result.length > 4096) throw Error('Invalid invitation');
  return result;
}

export function openLink(invitation, name) {
  return 'mavcontrol://join' + invitationFragment(invitation, name);
}
