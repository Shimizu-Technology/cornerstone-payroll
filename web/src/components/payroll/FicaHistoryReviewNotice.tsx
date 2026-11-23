import { useId, useState } from 'react';
import { Button } from '@/components/ui/button';
import type { PayPeriod } from '@/types';

type ReviewPeriod = Pick<PayPeriod, 'annual_fica_review' | 'annual_fica_review_note'>;

export function FicaHistoryReviewNotice({ payPeriod, showDisclosure = false }: { payPeriod: ReviewPeriod; showDisclosure?: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const detailsId = useId();
  const review = payPeriod.annual_fica_review;
  const entries = review?.entries ?? (payPeriod.annual_fica_review_note?.split('\n').filter(Boolean) ?? [])
    .map(note => ({ employee_name: '', note }));
  const count = review?.employee_count ?? entries.length;
  if (!count) return null;

  return (
    <div className="text-sm text-neutral-700">
      <div className="flex flex-wrap items-center gap-x-2">
        <p>{count} payroll history {count === 1 ? 'item' : 'items'} awaiting accountant review. This payroll isn't affected.</p>
        {showDisclosure && <Button type="button" variant="ghost" size="sm" className="min-h-11 underline underline-offset-4"
          aria-expanded={expanded} aria-controls={detailsId} onClick={() => setExpanded(value => !value)}>
          {expanded ? 'Hide details' : 'Show details'}
        </Button>}
      </div>
      {showDisclosure && <ul id={detailsId} hidden={!expanded} className="space-y-2 py-2">
        {entries.map((entry, index) => <li key={index} className="break-words">
          {entry.employee_name && <strong>{entry.employee_name}: </strong>}{entry.note}
        </li>)}
      </ul>}
    </div>
  );
}
