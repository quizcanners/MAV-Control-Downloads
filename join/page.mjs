import {readInvitation, validName, invitationFragment, openLink} from './invitation.mjs';

const heading = document.querySelector('#inviter');
try {
  const entry = readInvitation(location.hash);
  heading.textContent = 'Запрошує / Invited by: ' + entry.inviter;
  document.querySelector('#journey').hidden = false;
  const name = document.querySelector('#name'), open = document.querySelector('#open');
  name.value = entry.name;
  function refresh() {
    const value = name.value.trim(), okay = validName(value);
    open.setAttribute('aria-disabled', String(!okay));
    if (okay) {
      open.href = openLink(entry.invitation, value);
    } else open.removeAttribute('href');
    // Keep only the currently accepted name. An invalid edit must not restore
    // a previously accepted name after a reload or an installer trip.
    const fragment = okay ? invitationFragment(entry.invitation, value)
      : '#invite=' + encodeURIComponent(entry.invitation);
    history.replaceState(null, '', location.pathname + fragment);
    document.querySelector('#nameIssue').textContent = okay ? ''
      : 'Введіть ім’я щонайменше з 5 символів / Enter a name of at least 5 characters';
  }
  name.addEventListener('input', refresh);
  window.addEventListener('hashchange', () => location.reload());
  refresh();
} catch {
  heading.textContent = 'Недійсне запрошення. Попросіть новий QR-код / Invalid invitation. Ask for a new QR code.';
}
