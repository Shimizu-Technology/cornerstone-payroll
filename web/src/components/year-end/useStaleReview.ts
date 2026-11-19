import { useState } from 'react';
import { ApiError } from '@/services/api';
import { useStillMounted } from './useStillMounted';

export function isStaleReview(err: unknown): boolean {
  return err instanceof ApiError && err.status === 409;
}

/**
 * After the server refuses a review because its data changed (409), the
 * reviewer keeps their note, refreshes the checklist, and must confirm they
 * looked at the refreshed details before submitting again. Nothing is ever
 * resubmitted on their behalf with the new digest.
 */
export function useStaleReview(digest: string, onRefresh: () => Promise<void>) {
  const [refusedDigest, setRefusedDigest] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [confirmed, setConfirmed] = useState(false);
  const stillMounted = useStillMounted();
  const refused = refusedDigest !== null;
  const refreshed = refused && digest !== refusedDigest;

  return {
    refused,
    refreshed,
    refreshing,
    confirmed,
    setConfirmed,
    /** Submitting is allowed once nothing is pending from a refusal. */
    canSubmit: !refused || (refreshed && confirmed),
    markRefused: () => { setRefusedDigest(digest); setConfirmed(false); },
    clear: () => { setRefusedDigest(null); setConfirmed(false); },
    refresh: async () => {
      setRefreshing(true);
      try {
        await onRefresh();
      } finally {
        if (stillMounted()) setRefreshing(false);
      }
    },
  };
}
