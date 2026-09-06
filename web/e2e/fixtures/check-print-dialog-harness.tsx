import { useState, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { UnifiedCheckPrintDialog } from '@/components/checks/UnifiedCheckPrintDialog';

let root: Root | null = null;

function renderHarness(element: ReactNode): void {
  let container = document.querySelector<HTMLDivElement>('[data-testid="check-print-dialog-harness-root"]');
  if (!container) {
    container = document.createElement('div');
    container.dataset.testid = 'check-print-dialog-harness-root';
    document.body.appendChild(container);
  }
  root ||= createRoot(container);
  root.render(element);
}

function CheckPrintDialogHarness(): ReactNode {
  const [open, setOpen] = useState(true);

  return (
    <UnifiedCheckPrintDialog
      open={open}
      payPeriodId={703}
      onOpenChange={setOpen}
      onConfirmed={(): void => undefined}
    />
  );
}

export function mountCheckPrintDialogHarness(): void {
  renderHarness(<CheckPrintDialogHarness />);
}
