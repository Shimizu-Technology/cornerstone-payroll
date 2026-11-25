// Sign-up helpers kept out of signup.tsx so it exports only components.

// An invite link (/activate#token=…, /claim#token=…, /reactivate#token=…,
// EmployeeLinks::AppUrl) carries its token after "#", so it never reaches a
// server log or a Referer header. It's read once and taken out of the
// address bar. Claim and reactivate need a sign-in first, which can leave the
// page (Google sign-in is a full-page redirect), so the token is also kept in
// sessionStorage: this tab only, gone when the tab closes, and cleared once
// it's used, on Back to Welcome and on sign-out. Nothing else from sign-up,
// and never pay data, is stored.
const STORAGE_KEY = 'employee-invite-token';

let inviteToken: string | null = null;

const TOKEN = /^[A-Za-z0-9_-]{16,256}$/;

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

/** Reads #token from the address, keeps it for this tab, and takes it out of the address bar. */
export function takeInviteToken(location: { hash: string }): void {
  const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('token');
  if (token === null) return;
  if (TOKEN.test(token)) {
    inviteToken = token;
    try {
      storage()?.setItem(STORAGE_KEY, token);
    } catch {
      // Storage full or blocked: the token still lasts until the page reloads.
    }
  }
  window.history.replaceState(window.history.state, '', `${window.location.pathname}${window.location.search}`);
}

/** Strips any initial #token= fragment before analytics (posthog-js) initializes. */
export function captureInitialInviteToken(): void {
  if (typeof window === 'undefined') return;
  takeInviteToken(window.location);
}

export function currentInviteToken(): string | null {
  if (inviteToken) return inviteToken;
  let stored: string | null = null;
  try {
    stored = storage()?.getItem(STORAGE_KEY) ?? null;
  } catch {
    stored = null;
  }
  if (stored && TOKEN.test(stored)) inviteToken = stored;
  return inviteToken;
}

export function forgetInviteToken(): void {
  inviteToken = null;
  try {
    storage()?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing stored.
  }
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
