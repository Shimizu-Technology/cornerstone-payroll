import { useState, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { ImportModal } from '@/components/import/ImportModal';
import { PayrollIntakeImportModal } from '@/components/import/PayrollIntakeImportModal';
import type { Employee } from '@/types';

let root: Root | null = null;

function renderHarness(element: ReactNode): void {
  let container = document.querySelector<HTMLDivElement>('[data-testid="import-dialog-harness-root"]');
  if (!container) {
    container = document.createElement('div');
    container.dataset.testid = 'import-dialog-harness-root';
    document.body.appendChild(container);
  }
  root ||= createRoot(container);
  root.render(element);
}

function ImportModalHarness(): ReactNode {
  const [open, setOpen] = useState(true);

  return (
    <>
      {!open && <button type="button" onClick={(): void => setOpen(true)}>Open payroll import</button>}
      <ImportModal
        open={open}
        onOpenChange={setOpen}
        payPeriodId={701}
        onImportComplete={(): void => undefined}
      />
    </>
  );
}

const fixtureEmployee: Employee = {
  id: 801,
  company_id: 1,
  first_name: 'Existing',
  last_name: 'Employee',
  employment_type: 'hourly',
  pay_rate: 12,
  pay_frequency: 'biweekly',
  filing_status: 'single',
  allowances: 0,
  additional_withholding: 0,
  w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false,
  w4_step4a_other_income: 0,
  w4_step4b_deductions: 0,
  w4_form_version: 2020,
  retirement_rate: 0,
  roth_retirement_rate: 0,
  status: 'active',
  created_at: '2026-09-07T00:00:00Z',
  updated_at: '2026-09-07T00:00:00Z',
};

function PayrollIntakeModalHarness(): ReactNode {
  const [open, setOpen] = useState(true);

  return (
    <>
      {!open && <button type="button" onClick={(): void => setOpen(true)}>Open payroll intake</button>}
      <PayrollIntakeImportModal
        open={open}
        onOpenChange={setOpen}
        payPeriodId={702}
        employees={[fixtureEmployee]}
        onImportComplete={(): void => undefined}
      />
    </>
  );
}

export function mountImportModalHarness(): void {
  renderHarness(<ImportModalHarness />);
}

export function mountPayrollIntakeModalHarness(): void {
  renderHarness(<PayrollIntakeModalHarness />);
}
