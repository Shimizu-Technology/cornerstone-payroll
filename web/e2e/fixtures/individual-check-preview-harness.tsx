import { createRoot } from 'react-dom/client';
import { MemoryRouter } from 'react-router';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { ChecksPanel } from '@/components/payroll/ChecksPanel';
import { NonEmployeeChecksPanel } from '@/components/checks/NonEmployeeChecksPanel';
import { ChecksPayments } from '@/pages/ChecksPayments';
import type { PayPeriod } from '@/types';

export function mountIndividualCheckHarness(surface: 'payroll' | 'period' | 'payments'): void {
  document.getElementById('root')?.remove();
  const container = document.createElement('div');
  document.body.appendChild(container);
  createRoot(container).render(<MemoryRouter><FeedbackProvider>
    {surface === 'payroll' ? <ChecksPanel payPeriod={{ id: 8, status: 'committed', pay_date: '2026-10-08' } as PayPeriod} />
      : surface === 'period' ? <NonEmployeeChecksPanel companyId={1} payPeriodId={8} payPeriodStatus="committed" />
      : <ChecksPayments />}
  </FeedbackProvider></MemoryRouter>);
}
