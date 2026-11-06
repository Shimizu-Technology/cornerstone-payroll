import { Link } from 'react-router';

export function PriorProviderHistoryNotice({ companyId }: { companyId: number }) {
  return <aside className="mb-4 space-y-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-6 text-primary-950" aria-label="Previous provider payroll">
    <p className="font-semibold">Were these already paid by a previous provider?</p>
    <p>Compare the saved calculations with their paid registers, enter their check numbers, and carry the totals into year-to-date. Only approve payroll that still needs to be paid.</p>
    <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={`/companies/${companyId}/prior-provider-history`}>Record them as prior-provider history</Link>
  </aside>;
}

export function PriorProviderHistoryRecordedNotice({ companyId, periodCount }: { companyId: number; periodCount: number }) {
  return <aside className="mb-4 space-y-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-6 text-primary-950" aria-label="Recorded previous provider history">
    <p className="font-semibold">{periodCount} pay {periodCount === 1 ? 'run is' : 'runs are'} recorded as previous-provider history. Turn on YTD to finish.</p>
    <p>{periodCount === 1 ? 'It appears' : 'They appear'} in this list after year-to-date is turned on. Live payroll can start after that.</p>
    <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={`/companies/${companyId}/prior-provider-history`}>Turn on YTD</Link>
  </aside>;
}
