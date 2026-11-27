/**
 * Where to go after signing in: the page that sent the person to sign-in, or
 * Home. Only same-site paths: "//host" and "/\host" would leave the site.
 */
export function redirectTarget(state: unknown): string {
  const from = (state as { from?: unknown } | null)?.from;
  // Control characters too: URL parsing drops tab and newlines, so "/\t/host" would leave the site.
  // eslint-disable-next-line no-control-regex
  if (typeof from !== 'string' || !from.startsWith('/') || from.includes('\\') || /[\u0000-\u001f\u007f]/.test(from)) return '/';
  return from.startsWith('//') || from.startsWith('/sign-in') ? '/' : from;
}

// Set when the person taps Sign out. The signed-out routes then go to Welcome
// instead of treating the page they were on as a deep link to come back to.
let signingOut = false;

export function markSigningOut(): void {
  signingOut = true;
}

export function isSigningOut(): boolean {
  return signingOut;
}

/** Called once the Welcome screen shows, so a later deep link works as usual. */
export function clearSigningOut(): void {
  signingOut = false;
}
