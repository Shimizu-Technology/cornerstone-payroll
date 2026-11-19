import type { ReactElement } from 'react';
import { Button } from '@/components/ui/button';
import type { useStaleReview } from './useStaleReview';

export function StaleReviewNotice({ stale, idPrefix, what }: {
  stale: ReturnType<typeof useStaleReview>;
  idPrefix: string;
  what: string;
}): ReactElement | null {
  if (!stale.refused) return null;
  if (!stale.refreshed) {
    return (
      <div role="alert" className="rounded-xl border border-warning-200 bg-warning-50/50 p-3 text-sm text-warning-900">
        <p>The {what} changed after this page loaded, so nothing was saved. Your note is kept. Refresh the checklist to see the new details.</p>
        <Button type="button" size="sm" variant="outline" className="mt-2" loading={stale.refreshing} loadingLabel="Refreshing…" onClick={() => void stale.refresh()}>
          Refresh checklist
        </Button>
      </div>
    );
  }
  return (
    <div className="rounded-xl border border-warning-200 bg-warning-50/50 p-3 text-sm text-warning-900">
      <p role="status">The {what} above are updated. Review them before you submit again.</p>
      <label htmlFor={`${idPrefix}-reviewed`} className="mt-2 flex min-h-11 cursor-pointer items-center gap-2 font-medium">
        <input
          id={`${idPrefix}-reviewed`}
          type="checkbox"
          checked={stale.confirmed}
          onChange={(event) => stale.setConfirmed(event.target.checked)}
          className="h-4 w-4 shrink-0 accent-primary-700"
        />
        I reviewed the updated {what}
      </label>
    </div>
  );
}
