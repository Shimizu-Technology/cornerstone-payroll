const AUTH_RETURN_STORAGE_KEY = 'cornerstone_auth_return_to';
const INTERNAL_ORIGIN = 'https://cornerstone-payroll.local';
const MAX_AUTH_RETURN_URL_LENGTH = 2048;
const DISALLOWED_RETURN_PREFIXES = ['/login', '/invite', '/callback'];

function hasControlCharacters(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function isDisallowedAuthPath(pathname: string): boolean {
  const lower = pathname.toLowerCase();
  return DISALLOWED_RETURN_PREFIXES.some((prefix) => lower === prefix || lower.startsWith(`${prefix}/`));
}

/**
 * Accepts only same-site relative paths (`^/(?!/|\\)`) that cannot redirect
 * off-origin or loop back into `/login`, `/invite`, or `/callback`.
 */
export function sanitizeAuthReturnPath(value: string | null | undefined): string | null {
  if (
    !value
    || value.length > MAX_AUTH_RETURN_URL_LENGTH
    || hasControlCharacters(value)
    || !value.startsWith('/')
    || value.startsWith('//')
    || value.includes('\\')
  ) {
    return null;
  }

  try {
    const parsed = new URL(value, INTERNAL_ORIGIN);
    if (parsed.origin !== INTERNAL_ORIGIN || parsed.username !== '' || parsed.password !== '') {
      return null;
    }

    if (/^\/[/\\]/.test(parsed.pathname)) return null;

    const decodedPathname = decodeURIComponent(parsed.pathname);
    if (
      hasControlCharacters(decodedPathname)
      || /^\/[/\\]/.test(decodedPathname)
      || decodedPathname.includes('\\')
      || isDisallowedAuthPath(parsed.pathname)
      || isDisallowedAuthPath(decodedPathname)
    ) {
      return null;
    }

    const normalized = `${parsed.pathname}${parsed.search}${parsed.hash}`;
    if (normalized.length > MAX_AUTH_RETURN_URL_LENGTH) return null;
    if (new URL(normalized, INTERNAL_ORIGIN).origin !== INTERNAL_ORIGIN) return null;

    return normalized;
  } catch {
    return null;
  }
}

export function resolveAuthReturnPath(value: string | null | undefined, fallback = '/app'): string {
  return sanitizeAuthReturnPath(value) ?? fallback;
}

export function loginRedirectPath(location: { pathname: string; search?: string; hash?: string }): string {
  const requested = sanitizeAuthReturnPath(`${location.pathname}${location.search ?? ''}${location.hash ?? ''}`);
  if (!requested || requested === '/' || requested === '/app') return '/login';
  return `/login?return_to=${encodeURIComponent(requested)}`;
}

export function rememberAuthReturnPath(path: string | null | undefined): void {
  const safe = sanitizeAuthReturnPath(path);
  if (!safe || safe === '/' || safe === '/app') return;
  try {
    window.sessionStorage.setItem(AUTH_RETURN_STORAGE_KEY, safe);
  } catch {
    // Ignore storage failures when sessionStorage is unavailable.
  }
}

export function readStoredAuthReturnPath(): string | null {
  try {
    return sanitizeAuthReturnPath(window.sessionStorage.getItem(AUTH_RETURN_STORAGE_KEY));
  } catch {
    return null;
  }
}

export function clearStoredAuthReturnPath(): void {
  try {
    window.sessionStorage.removeItem(AUTH_RETURN_STORAGE_KEY);
  } catch {
    // Ignore storage failures when sessionStorage is unavailable.
  }
}
