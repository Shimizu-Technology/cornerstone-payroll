import { AlertCircle, CheckCircle2 } from 'lucide-react';
import { Link } from 'react-router';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { formatDate } from '@/lib/display-date';
import type { EmployeeReadiness, ReadinessKey } from '@/services/clientEmployeeLifecycle';

const readinessLabels = {
  ready: 'Ready to pay',
  incomplete: "Incomplete — can’t be paid yet",
  missing_items: 'Missing items',
} as const;

const setupSections: Record<ReadinessKey, string> = {
  legal_name: 'employee-personal',
  tax_id: 'employee-personal',
  date_of_birth: 'employee-personal',
  hire_date: 'employee-employment',
  home_address: 'employee-address',
  pay_setup: 'employee-employment',
  payment_method: 'employee-employment',
  tax_form: 'employee-tax',
};

export function EmployeeReadinessBadge({ status }: { status: EmployeeReadiness['status'] }) {
  return <Badge variant={status === 'ready' ? 'success' : 'warning'} className="whitespace-normal">{readinessLabels[status]}</Badge>;
}

export function DirectDepositSetupNote() {
  return <p className="rounded-lg border border-primary-100 bg-primary-50 p-3 text-sm text-primary-900">
    Direct deposit selected. Cornerstone will confirm bank setup before payday.
  </p>;
}

export function EmployeeReadinessCard({ readiness, setupPath, isBusinessContractor, businessNameMissing, preview = false, showBankNote = true }: {
  readiness: EmployeeReadiness;
  setupPath?: string;
  isBusinessContractor?: boolean;
  businessNameMissing?: boolean;
  preview?: boolean;
  showBankNote?: boolean;
}) {
  const firstMissing = readiness.items.find((item) => item.applicable && !item.complete);
  const section = firstMissing && (isBusinessContractor && (
    firstMissing.key === 'tax_id' || (firstMissing.key === 'legal_name' && businessNameMissing)
  ) ? 'employee-tax' : setupSections[firstMissing.key]);

  return (
    <Card className={preview ? 'border-neutral-200 shadow-none' : undefined}>
      <CardHeader className="gap-2">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <CardTitle>{preview ? 'Ready to pay after rehire' : 'Ready to pay'}</CardTitle>
          <EmployeeReadinessBadge status={readiness.status} />
        </div>
        <p className="text-sm leading-5 text-neutral-600">
          Pay setup as of {formatDate(readiness.rates_on)}. Withholding as of {formatDate(readiness.w4_on)}.
        </p>
        {readiness.status === 'missing_items' && <p className="text-sm text-neutral-600">This employee can still be paid while you finish these items.</p>}
      </CardHeader>
      <CardContent className="space-y-4">
        <ul className="grid gap-x-5 gap-y-2 sm:grid-cols-2">
          {readiness.items.filter((item) => item.applicable).map((item) => {
            const Icon = item.complete ? CheckCircle2 : AlertCircle;
            const text = item.missing_label;
            return <li key={item.key} className="flex min-w-0 items-start gap-2 text-sm text-neutral-800">
              <Icon className={`mt-0.5 h-4 w-4 shrink-0 ${item.complete ? 'text-success-700' : 'text-warning-700'}`} aria-hidden="true" />
              <span className="wrap-anywhere">
                {item.complete ? <><span className="sr-only">Complete: </span>{item.label}</> : text ? text.charAt(0).toUpperCase() + text.slice(1) : item.label}
              </span>
            </li>;
          })}
        </ul>
        {showBankNote && readiness.direct_deposit_missing_bank_details && <DirectDepositSetupNote />}
        {section && setupPath !== undefined && <Link to={`${setupPath}#${section}`} className="inline-flex min-h-11 items-center rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 hover:bg-neutral-50">Complete setup</Link>}
      </CardContent>
    </Card>
  );
}
