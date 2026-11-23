// Pages that must render for signed-out visitors without waiting for Clerk or
// the company context. Google's consent-screen review fetches the legal pages.
const PUBLIC_PATHS = new Set(['/', '/login', '/invite', '/privacy', '/terms']);

export function isPublicPath(pathname: string): boolean {
  // React Router also matches "/privacy/", so ignore a trailing slash.
  return PUBLIC_PATHS.has(pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname);
}
