import type { BoundedListMeta } from '@/services/api';

// Appends a later page, skipping rows already on screen. A row can repeat when
// something new is added between page requests and shifts the offsets.
export function appendUniqueById<T extends { id: number }>(current: T[], next: T[]): T[] {
  const seen = new Set(current.map((row) => row.id));
  return [...current, ...next.filter((row) => !seen.has(row.id))];
}

export function hasMorePages(meta: BoundedListMeta | null | undefined): boolean {
  return Boolean(meta && meta.current_page < meta.total_pages);
}
