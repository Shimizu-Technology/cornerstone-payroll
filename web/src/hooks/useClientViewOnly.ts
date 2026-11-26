import { useOptionalAuth } from '@/contexts/AuthContext';

/**
 * True for a read-only Client viewer login; staff and Client managers get
 * false. Outside the auth provider (embedded dialogs, isolated tests) it is
 * false too: this only hides controls, and the API refuses a viewer's writes.
 */
export function useClientViewOnly(): boolean {
  return useOptionalAuth()?.isClientViewer === true;
}
