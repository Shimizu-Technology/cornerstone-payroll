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
      {!open && <button type="button" onClick={() => setOpen(true)}>Open payroll import</button>}
      <ImportModal
        open={open}
        onOpenChange={setOpen}
        payPeriodId={701}
        onImportComplete={() => undefined}
      />
    </>
  );
}

const fixtureEmployee = {
  id: 801,
  company_id: 1,
  first_name: 'Existing',
  last_name: 'Employee',
} as Employee;

function PayrollIntakeModalHarness(): ReactNode {
  const [open, setOpen] = useState(true);

  return (
    <>
      {!open && <button type="button" onClick={() => setOpen(true)}>Open payroll intake</button>}
      <PayrollIntakeImportModal
        open={open}
        onOpenChange={setOpen}
        payPeriodId={702}
        employees={[fixtureEmployee]}
        onImportComplete={() => undefined}
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
