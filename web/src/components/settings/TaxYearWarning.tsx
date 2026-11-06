import { useEffect, useState } from 'react';
import { taxYearReadinessApi, type TaxYearReadiness } from '@/services/api';

export function TaxYearWarning({ companyId, payDate }: { companyId: number | null; payDate?: string }) {
  const [readiness, setReadiness] = useState<TaxYearReadiness | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let current = true;
    taxYearReadinessApi.get().then(value => { if (current) { setReadiness(value); setFailed(false); } })
      .catch(() => { if (current) setFailed(true); });
    return () => { current = false; };
  }, [companyId]);
  const year = payDate ? Number(payDate.slice(0, 4)) : null;
  const messages = year
    ? readiness && !readiness.verified_years.includes(year)
      ? [`${year} tax tables have not been verified. An administrator must verify them before ${year} payroll can be calculated.`] : []
    : readiness?.warnings.map(warning => warning.message) ?? [];
  if (failed) messages.push('Tax-year readiness could not be checked. Payroll calculation will require verified tables for the pay date.');
  if (!messages.length) return null;
  return <div role="status" className="mb-4 space-y-2 rounded-lg border border-warning-200 bg-warning-50 p-4 text-sm text-warning-800">
    {messages.map(message => <p key={message}>{message}</p>)}
    <p>You can save a draft pay period while an administrator reviews tax setup.</p>
  </div>;
}
