// Sign-up helpers kept out of signup.tsx so it exports only components.

// An invite link carries its token after "#", so it never reaches a server log
// or a Referer header. It's read once, kept in memory only, and taken out of
// the address bar.
let inviteToken: string | null = null;

const TOKEN = /^[A-Za-z0-9_-]{16,256}$/;

export function takeInviteToken(location: { hash: string; search: string }): void {
  const fromHash = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  const token = fromHash ?? new URLSearchParams(location.search).get('token');
  if (!token) return;
  if (TOKEN.test(token)) inviteToken = token;
  window.history.replaceState(window.history.state, '', window.location.pathname);
}

export function currentInviteToken(): string | null {
  return inviteToken;
}

export function forgetInviteToken(): void {
  inviteToken = null;
}

/** Codes are 10 unambiguous letters; people type them with spaces, dashes and any case. */
export function normalizeCode(value: string): string {
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

/** "1990-04-07", or null when it isn't a real date someone could be born on. */
export function birthDate(draft: { month: string; day: string; year: string }, now = new Date()): string | null {
  const [month, day, year] = [Number(draft.month), Number(draft.day), Number(draft.year)];
  if (!Number.isInteger(month) || !Number.isInteger(day) || !Number.isInteger(year)) return null;
  if (year < 1900 || year > now.getFullYear() - 10) return null;
  const date = new Date(year, month - 1, day);
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return null;
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}
