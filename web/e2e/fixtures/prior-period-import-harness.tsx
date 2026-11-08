import { createRoot } from 'react-dom/client';
import { MemoryRouter } from 'react-router';
import { AuthProvider } from '@/contexts/AuthContext';
import { CompanyProvider } from '@/contexts/CompanyContext';
import { TimeTrackingImportModal } from '@/components/payroll/TimeTrackingImportModal';
import { PayrollResultBreakdown } from '@/components/payroll/PayrollResultBreakdown';
import type { Employee, PayPeriod } from '@/types';

export function mountPriorPeriodImport() {
  const container = document.createElement('div');
  document.body.appendChild(container);
  const payPeriod = { id: 2, company_id: 1, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15', status: 'draft', run_purpose: 'regular' } as PayPeriod;
  const employee = { id: 7, company_id: 1, first_name: 'Casey', last_name: 'Example', employment_type: 'hourly', wage_rates: [{ id: 1, label: 'Admin Duties', rate: 10, active: true, is_primary: true }] } as Employee;
  createRoot(container).render(<MemoryRouter><AuthProvider><CompanyProvider><TimeTrackingImportModal open onClose={() => undefined} payPeriod={payPeriod} employees={[employee]} initialSourceId={1} autoPreview onImportComplete={async () => true} /></CompanyProvider></AuthProvider></MemoryRouter>);
}

export function mountSavedLeaveDisclosure() {
  const container = document.createElement('div');
  container.dataset.testid = 'saved-leave-disclosure';
  document.body.appendChild(container);
  createRoot(container).render(<PayrollResultBreakdown disclosure={{
    earnings: [{ label: 'Admin Duties · AIRE carryover from Sep 15, 2026 · $10.00/hr PTO', display_label: 'Admin Duties PTO', amount: 20 }],
    other_pay: [], taxes: [], deductions: [], employer_contributions: [],
    reconciliation: { gross_pay: 20, other_pay: 0, employee_taxes: 0, other_deductions: 0, net_pay: 20 },
  }} />);
}
