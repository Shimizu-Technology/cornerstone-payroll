import { Component, lazy, Suspense, useState, type ReactNode } from 'react';
import { Link } from 'react-router';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { payrollItemPath } from '@/lib/routes';

const loadDetail = () => lazy(() => import('@/pages/payroll-items/PayrollItemDetail').then(module => ({ default: module.PayrollItemDetail })));

export class PayrollDetailBoundary extends Component<{ children: ReactNode; onRetry: () => void }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    if (this.state.failed) return <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-900">
      <p>Payroll details could not load. Your worksheet entries are still here. Close this dialog to continue, or retry the details.</p>
      <Button variant="outline" className="mt-3" onClick={this.props.onRetry}>Retry details</Button>
    </div>;
    return this.props.children;
  }
}

type Props = {
  companyId: number;
  payRunId: number;
  item: { id: number; employee_name?: string } | null;
  returnTo: string;
  onClose: () => void;
};

export function PayrollItemReviewDialog({ companyId, payRunId, item, returnTo, onClose }: Props) {
  const [detail, setDetail] = useState(() => ({ Component: loadDetail(), attempt: 0 }));
  const PayrollItemDetail = detail.Component;
  return <Dialog open={item !== null} onOpenChange={open => { if (!open) onClose(); }}>
    {item && <DialogContent className="dialog-wide dialog-top">
      <DialogHeader className="flex-row flex-wrap items-start justify-between gap-3 text-left">
        <div><DialogTitle>{item.employee_name || 'Employee'} · Payroll details</DialogTitle>
          <DialogDescription className="mt-2">Review this saved result. Close to continue where you left off.</DialogDescription></div>
        <Button variant="outline" onClick={onClose}>Close details</Button>
      </DialogHeader>
      <PayrollDetailBoundary key={`${companyId}:${payRunId}:${item.id}:${detail.attempt}`} onRetry={() => setDetail(current => ({ Component: loadDetail(), attempt: current.attempt + 1 }))}>
      <Suspense fallback={<WorkspaceLoader label="Loading payroll details" />}>
        <PayrollItemDetail key={`${companyId}:${payRunId}:${item.id}`} embedded record={{ companyId, payRunId, payrollItemId: item.id }} />
      </Suspense>
      </PayrollDetailBoundary>
      <Link className="mt-4 inline-flex min-h-11 items-center text-sm font-semibold text-primary-700 underline" to={payrollItemPath(companyId, payRunId, item.id, { returnTo })}>Open full payroll record</Link>
    </DialogContent>}
  </Dialog>;
}
