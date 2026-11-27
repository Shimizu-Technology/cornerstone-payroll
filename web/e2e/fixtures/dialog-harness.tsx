import { useState, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { beginStepUpOverlay } from '@/components/ui/dialog-overlay';

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

function StepUpDialogHarness(): ReactNode {
  const [open, setOpen] = useState(true);
  const [status, setStatus] = useState('Waiting for verification');

  const triggerStepUp = (): void => {
    const release = beginStepUpOverlay();
    const portal = document.createElement('div');
    portal.setAttribute('data-floating-ui-portal', '');
    portal.setAttribute('data-testid', 'stub-clerk-portal');

    const backdrop = document.createElement('div');
    backdrop.className = 'cl-modalBackdrop fixed inset-0 z-[200] flex items-center justify-center bg-black/40';

    const content = document.createElement('div');
    content.className = 'cl-modalContent rounded-lg bg-white p-6 shadow-xl';
    content.setAttribute('role', 'dialog');
    content.setAttribute('aria-modal', 'true');
    content.setAttribute('aria-label', 'Verification required');

    const heading = document.createElement('h3');
    heading.textContent = 'Verification required';

    const input = document.createElement('input');
    input.type = 'password';
    input.setAttribute('aria-label', 'Clerk password');
    input.placeholder = 'Enter password';

    const submit = document.createElement('button');
    submit.type = 'button';
    submit.textContent = 'Continue';
    submit.addEventListener('click', () => {
      setStatus(`Verified: ${input.value}`);
      portal.remove();
      release();
    });

    content.append(heading, input, submit);
    backdrop.append(content);
    portal.append(backdrop);
    document.body.appendChild(portal);
    input.focus();
  };

  return (
    <div>
      <button type="button" data-testid="background-page-btn">Background page button</button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogTitle>Step-up inside dialog test</DialogTitle>
          <p data-testid="stepup-status">{status}</p>
          <button type="button" onClick={triggerStepUp}>Turn on</button>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export function mountLivePropDialogHarness(): void {
  renderHarness(<LivePropHarness />);
}

export function mountDefaultDialogHarness(): void {
  renderHarness(<DefaultHarness />);
}

export function mountStepUpDialogHarness(): void {
  renderHarness(<StepUpDialogHarness />);
}
