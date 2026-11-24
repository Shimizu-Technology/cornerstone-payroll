export function apiOrigin(apiUrl: unknown): string
export function clerkFrontendOrigin(publishableKey: unknown, options?: { production?: boolean }): string
export function contentSecurityPolicy(origins: { apiOrigin: string; clerkOrigin: string }): string
export function renderHeaders(template: string, origins: { apiOrigin: string; clerkOrigin: string }): string
export function finalizeEmployeeDist(options: {
  distDir: string
  deployDir: string
  env: Record<string, string | undefined>
}): { apiOrigin: string; clerkOrigin: string }
export function main(env?: Record<string, string | undefined>): void
