import { Link } from 'react-router';

export function PriorProviderHistoryNotice({ companyId }: { companyId: number }) {
  return <aside className="mb-4 space-y-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-6 text-primary-950" aria-label="Previous provider payroll">
    <p className="font-semibold">Were these already paid by a previous provider?</p>
    <p>Compare the saved calculations with their paid registers, enter their check numbers, and carry the totals into year-to-date. Only approve payroll that still needs to be paid.</p>
    <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={`/companies/${companyId}/prior-provider-history`}>Record them as prior-provider history</Link>
  </aside>;
}
