/** Where to go after signing in: the page that sent the person to sign-in, or Home. */
export function redirectTarget(state: unknown): string {
  const from = (state as { from?: unknown } | null)?.from;
  return typeof from === 'string' && from.startsWith('/') && !from.startsWith('//') && !from.startsWith('/sign-in') ? from : '/';
}
