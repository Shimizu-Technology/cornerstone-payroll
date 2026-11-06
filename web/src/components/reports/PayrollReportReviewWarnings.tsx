import type { PayrollReportReviewWarning } from '@/services/api';

export function PayrollReportReviewWarnings({ warnings }: { warnings?: PayrollReportReviewWarning[] }) {
  const messages = [...new Set(warnings?.map((warning) => warning.message) || [])];
  if (messages.length === 0) return null;

  return (
    <div role="note" aria-label="Payroll history review required" className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950">
      <p className="font-semibold">Payroll history review required</p>
      {messages.map((message) => <p key={message}>{message}</p>)}
      <p className="mt-1">Saved amounts are shown once. Review this history before using it for a payroll correction or liability reconciliation.</p>
    </div>
  );
}
