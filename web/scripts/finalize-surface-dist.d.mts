export interface PostHogOrigins {
  apiOrigin: string
  assetsOrigin: string
}

export function apiOrigin(apiUrl: unknown): string
export function clerkFrontendOrigin(publishableKey: unknown, options?: { production?: boolean }): string
export function posthogOrigins(env?: Record<string, string | undefined>): PostHogOrigins | null
export function contentSecurityPolicy(origins: {
  apiOrigin: string
  clerkOrigin: string
  posthog?: PostHogOrigins | null
}): string
export function renderHeaders(
  template: string,
  origins: { apiOrigin: string; clerkOrigin: string; posthog?: PostHogOrigins | null },
): string
export function finalizeEmployeeDist(options: {
  distDir: string
  deployDir: string
  env: Record<string, string | undefined>
}): { apiOrigin: string; clerkOrigin: string; posthog: PostHogOrigins | null }
export function main(env?: Record<string, string | undefined>): void
