import { useState, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';

let root: Root | null = null;

function renderHarness(element: ReactNode): void {
  let container = document.querySelector<HTMLDivElement>('[data-testid="dialog-harness-root"]');
  if (!container) {
    container = document.createElement('div');
    container.dataset.testid = 'dialog-harness-root';
    document.body.appendChild(container);
  }
  root ||= createRoot(container);
  root.render(element);
}

function LivePropHarness(): ReactNode {
  const [dismissOnEscape, setDismissOnEscape] = useState(false);
  const [result, setResult] = useState('No close requested');

  return (
    <Dialog
      open
      dismissOnEscape={dismissOnEscape}
      onOpenChange={(nextOpen): void => {
        if (!nextOpen) setResult(dismissOnEscape ? 'Latest handler called' : 'Locked handler called');
      }}
    >
      <DialogContent>
        <DialogTitle>Shared dialog live-prop test</DialogTitle>
        <p data-testid="dialog-result">{result}</p>
        <button type="button" onClick={() => setDismissOnEscape(true)}>Allow Escape</button>
      </DialogContent>
    </Dialog>
  );
}

function DefaultHarness(): ReactNode {
  const [result, setResult] = useState('No close requested');

  return (
    <Dialog
      open
      onOpenChange={(nextOpen): void => {
        if (!nextOpen) setResult('Default handler called');
      }}
    >
      <DialogContent>
        <DialogTitle>Shared dialog default test</DialogTitle>
        <p data-testid="dialog-result">{result}</p>
      </DialogContent>
    </Dialog>
  );
}

export function mountLivePropDialogHarness(): void {
  renderHarness(<LivePropHarness />);
}

export function mountDefaultDialogHarness(): void {
  renderHarness(<DefaultHarness />);
}
