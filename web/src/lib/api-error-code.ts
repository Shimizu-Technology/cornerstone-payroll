/** The reason code an API error body carries (`{ code: "feature_off" }`), or null. */
export function apiErrorCode(error: unknown): string | null {
  if (error === null || typeof error !== 'object' || !('data' in error)) return null;
  const data = (error as { data?: unknown }).data;
  if (data === null || typeof data !== 'object') return null;
  const code = (data as { code?: unknown }).code;
  return typeof code === 'string' ? code : null;
}
