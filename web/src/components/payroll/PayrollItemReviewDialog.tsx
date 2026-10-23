import { lazy, Suspense } from 'react';
import { Link } from 'react-router';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { payrollItemPath } from '@/lib/routes';

const PayrollItemDetail = lazy(() => import('@/pages/payroll-items/PayrollItemDetail').then(module => ({ default: module.PayrollItemDetail })));

type Props = {
  companyId: number;
  payRunId: number;
  item: { id: number; employee_name?: string } | null;
  returnTo: string;
  onClose: () => void;
};

export function PayrollItemReviewDialog({ companyId, payRunId, item, returnTo, onClose }: Props) {
  return <Dialog open={item !== null} onOpenChange={open => { if (!open) onClose(); }}>
    {item && <DialogContent className="dialog-wide dialog-top">
      <DialogHeader className="flex-row flex-wrap items-start justify-between gap-3 text-left">
        <div><DialogTitle>{item.employee_name || 'Employee'} · Payroll details</DialogTitle>
          <DialogDescription className="mt-2">Review this saved result. Close to continue where you left off.</DialogDescription></div>
        <Button variant="outline" onClick={onClose}>Close details</Button>
      </DialogHeader>
      <Suspense fallback={<WorkspaceLoader label="Loading payroll details" />}>
        <PayrollItemDetail key={`${companyId}:${payRunId}:${item.id}`} embedded record={{ companyId, payRunId, payrollItemId: item.id }} />
      </Suspense>
      <Link className="mt-4 inline-flex min-h-11 items-center text-sm font-semibold text-primary-700 underline" to={payrollItemPath(companyId, payRunId, item.id, { returnTo })}>Open full payroll record</Link>
    </DialogContent>}
  </Dialog>;
}
