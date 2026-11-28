import { CheckCircle2, CircleAlert } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { formatDate } from '@/lib/display-date';
import type { ReadinessChecklist } from '@/services/staff-employee-lifecycle';

// TODO(L11): Share checklist rendering with EmployeeReadinessCard while preserving
// staff missing-only filtering and the client card's setup links and bank guidance.
export function StaffReadinessChecklist({ checklist, missingOnly = false }: {
  checklist: ReadinessChecklist;
  missingOnly?: boolean;
}) {
  const labels = { ready: 'Ready to pay', incomplete: 'Incomplete', missing_items: 'Missing items' };
  const items = checklist.items.filter(item => item.applicable && (!missingOnly || !item.complete));
  return <div className="space-y-2">
    <div className="flex flex-wrap items-center gap-2">
      <h3 className="font-semibold text-neutral-950">Payroll readiness</h3>
      <Badge variant={checklist.status === 'ready' ? 'success' : 'warning'}>{labels[checklist.status]}</Badge>
    </div>
    <p className="text-sm text-neutral-600">Pay setup as of {formatDate(checklist.rates_on)}. Withholding as of {formatDate(checklist.w4_on)}.</p>
    {items.length > 0 && <ul className="space-y-1.5 text-sm">
      {items.map(item => {
        const Icon = item.complete ? CheckCircle2 : CircleAlert;
        return <li key={item.key} className="flex min-w-0 items-start gap-2">
          <Icon className={`mt-0.5 size-4 shrink-0 ${item.complete ? 'text-success-700' : 'text-warning-700'}`} aria-hidden="true" />
          <span className="wrap-anywhere"><span className="sr-only">{item.complete ? 'Complete: ' : 'Missing: '}</span>{item.complete ? item.label : item.missing_label || item.label}</span>
        </li>;
      })}
    </ul>}
  </div>;
}
