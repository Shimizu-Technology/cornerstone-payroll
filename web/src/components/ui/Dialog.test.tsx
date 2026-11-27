// @vitest-environment jsdom
import * as React from 'react';
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import userEvent from '@testing-library/user-event';
import { NumericInput } from './numeric-input';
import { Dialog, DialogContent, DialogTitle } from './dialog';
import { beginStepUpOverlay } from './dialog-overlay';

afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

it('preserves the field chosen before initial dialog focus runs', () => {
  let initialFocus!: FrameRequestCallback;
  vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => { initialFocus = callback; return 1; });
  vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => {});
  render(<Dialog open onOpenChange={vi.fn()}><DialogContent>
    <DialogTitle>Review time</DialogTitle>
    <button type="button">First control</button>
    <textarea aria-label="Review reason" autoFocus />
  </DialogContent></Dialog>);
  const reason = screen.getByRole('textbox', { name: 'Review reason' });
  expect(document.activeElement).toBe(reason);
  act(() => initialFocus(16));
  expect(document.activeElement).toBe(reason);
});

it('keeps a closing dialog modal through exit and cancels removal when reopened', async () => {
  vi.useFakeTimers();
  const changed = vi.fn();
  const trigger = document.createElement('button');
  document.body.appendChild(trigger);trigger.focus();
  const view = (open: boolean): React.ReactElement => <Dialog open={open} onOpenChange={changed}><DialogContent><DialogTitle>Review</DialogTitle><button>Confirm</button></DialogContent></Dialog>;
  const { rerender } = render(view(true));
  rerender(view(false));
  expect(screen.getByRole('dialog', { name: 'Review' })).toBeTruthy();
  expect(trigger.hasAttribute('inert')).toBe(true);
  act(() => vi.advanceTimersByTime(60));
  rerender(view(true));
  act(() => vi.advanceTimersByTime(200));
  expect(screen.getByRole('dialog', { name: 'Review' })).toBeTruthy();
  rerender(view(false));
  act(() => vi.advanceTimersByTime(120));
  expect(screen.queryByRole('dialog')).toBeNull();
  expect(trigger.hasAttribute('inert')).toBe(false);
  expect(document.activeElement).toBe(trigger);
  trigger.remove();vi.useRealTimers();
});

it('returns to the explicit opener when an asynchronous action blurred it before opening', async () => {
  const opener = React.createRef<HTMLButtonElement>();
  const view = (open: boolean): React.ReactElement => <><button ref={opener}>Open PDF</button><button autoFocus>Other action</button>
    <Dialog open={open} onOpenChange={vi.fn()} returnFocusRef={opener}><DialogContent><DialogTitle>PDF</DialogTitle><button>Close PDF</button></DialogContent></Dialog></>;
  const { rerender } = render(view(false));
  rerender(view(true));
  rerender(view(false));
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  expect(document.activeElement).toBe(opener.current);
});


it('finishes a focused numeric draft before reopening with reset values', async () => {
  function Entry({ open }: { open: boolean }): React.ReactElement {
    const [value, setValue] = React.useState(10);
    React.useEffect(() => { if (open) setValue(10); }, [open]);
    return <Dialog open={open} onOpenChange={vi.fn()}><DialogContent><DialogTitle>Entry</DialogTitle>
      <NumericInput aria-label="Hours" value={value} onValueChange={next => setValue(next ?? 0)} />
    </DialogContent></Dialog>;
  }
  const user = userEvent.setup();
  const { rerender } = render(<Entry open />);
  const input = screen.getByRole('textbox', { name: 'Hours' });
  await user.clear(input); await user.type(input, '1');
  expect((input as HTMLInputElement).value).toBe('1');
  rerender(<Entry open={false} />); rerender(<Entry open />);
  await waitFor(() => expect((input as HTMLInputElement).value).toBe('10'));
});

it('hands off after release using the latest committed close callback', async (): Promise<void> => {
  const first = vi.fn();
  const committed = vi.fn((): void => { expect(screen.queryByRole('dialog')).toBeNull(); });
  const view = (open: boolean, after: () => void): React.ReactElement => <Dialog open={open} onOpenChange={vi.fn()} onAfterClose={after}><DialogContent><DialogTitle>Handoff</DialogTitle></DialogContent></Dialog>;
  const { rerender } = render(view(true, first));
  rerender(view(true, committed));
  rerender(view(false, committed));
  await waitFor(() => expect(committed).toHaveBeenCalledTimes(1));
  expect(first).not.toHaveBeenCalled();
});

it('returns to an explicit opener whose ref attaches after dialog acquisition in the same commit', async (): Promise<void> => {
  const opener = React.createRef<HTMLButtonElement>();
  const view = (open: boolean): React.ReactElement => <>
    <Dialog open={open} onOpenChange={vi.fn()} returnFocusRef={opener}><DialogContent><DialogTitle>Late opener</DialogTitle></DialogContent></Dialog>
    <button ref={opener}>Late attached opener</button>
  </>;
  const { rerender } = render(view(true));
  rerender(view(false));
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  expect(document.activeElement).toBe(opener.current);
});

it('returns to the explicit opener when unmounted before initial focus runs', async (): Promise<void> => {
  vi.spyOn(window, 'requestAnimationFrame').mockReturnValue(1);
  vi.spyOn(window, 'cancelAnimationFrame').mockImplementation((): void => {});
  const opener = React.createRef<HTMLButtonElement>();
  const view = (show: boolean): React.ReactElement => <>
    <button ref={opener}>Unmount opener</button><button autoFocus>Prior focus</button>
    {show && <Dialog open onOpenChange={vi.fn()} returnFocusRef={opener}><DialogContent><DialogTitle>Unmount</DialogTitle></DialogContent></Dialog>}
  </>;
  const { rerender } = render(view(true));
  await act(async (): Promise<void> => { rerender(view(false)); });
  expect(screen.queryByRole('dialog')).toBeNull();
  expect(opener.current?.closest('[inert]')).toBeNull();
  expect(document.activeElement).toBe(opener.current);
});

it('keeps portals inserted during a step-up interactive while keeping unrelated background inert', async () => {
  const user = userEvent.setup();
  const background = document.createElement('div');
  background.innerHTML = '<button type="button">Background action</button>';
  document.body.appendChild(background);
  const onDialogClose = vi.fn();

  render(
    <Dialog open onOpenChange={onDialogClose}>
      <DialogContent>
        <DialogTitle>Turn on employee app</DialogTitle>
        <button type="button">Turn on</button>
      </DialogContent>
    </Dialog>,
  );

  // Unrelated background elements are inert while the dialog is open.
  expect(background.hasAttribute('inert')).toBe(true);
  const unrelatedLate = document.createElement('div');
  document.body.appendChild(unrelatedLate);
  await waitFor(() => expect(unrelatedLate.hasAttribute('inert')).toBe(true));

  // Simulate Clerk opening a verification modal portal during a step-up.
  const releaseStepUp = beginStepUpOverlay();
  const clerkPortal = document.createElement('div');
  const submitted = vi.fn();
  clerkPortal.innerHTML = `
    <div class="cl-modalBackdrop">
      <div class="cl-modalContent" role="dialog" aria-modal="true" aria-label="Verification required">
        <input aria-label="Password" type="password" />
        <button type="button">Continue</button>
      </div>
    </div>
  `;
  const continueButton = clerkPortal.querySelector('button')!;
  continueButton.addEventListener('click', submitted);
  document.body.appendChild(clerkPortal);

  // Flush MutationObserver microtasks and verify the step-up portal is never made inert.
  await act(async () => { await Promise.resolve(); });
  expect(clerkPortal.hasAttribute('inert')).toBe(false);
  expect(clerkPortal.querySelector('.cl-modalContent')?.closest('[inert]')).toBeNull();

  const passwordInput = clerkPortal.querySelector<HTMLInputElement>('input[aria-label="Password"]')!;
  await user.click(passwordInput);
  await user.type(passwordInput, 'synthetic-pass');
  expect(passwordInput.value).toBe('synthetic-pass');

  // Escape inside the Clerk modal must not dismiss the underlying app dialog.
  await user.keyboard('{Escape}');
  expect(onDialogClose).not.toHaveBeenCalled();

  await user.click(continueButton);
  expect(submitted).toHaveBeenCalledTimes(1);

  // Clean up the step-up overlay and confirm subsequent non-Clerk nodes are still inerted.
  clerkPortal.remove();
  releaseStepUp();
  const postStepUpUnrelated = document.createElement('div');
  document.body.appendChild(postStepUpUnrelated);
  await waitFor(() => expect(postStepUpUnrelated.hasAttribute('inert')).toBe(true));
  expect(background.hasAttribute('inert')).toBe(true);

  // Dialog Escape resumes working once the Clerk overlay is gone.
  await user.keyboard('{Escape}');
  expect(onDialogClose).toHaveBeenCalledWith(false);

  background.remove();
  unrelatedLate.remove();
  postStepUpUnrelated.remove();
});

it('exempts Clerk-marked roots even when inserted outside an explicit step-up window', async () => {
  render(
    <Dialog open onOpenChange={vi.fn()}>
      <DialogContent>
        <DialogTitle>Confirm rollback</DialogTitle>
        <button type="button">Confirm</button>
      </DialogContent>
    </Dialog>,
  );

  const clerkRoot = document.createElement('div');
  clerkRoot.className = 'cl-rootBox cl-userVerification-root';
  clerkRoot.innerHTML = '<input aria-label="Code" />';
  document.body.appendChild(clerkRoot);

  await act(async () => { await Promise.resolve(); });
  expect(clerkRoot.hasAttribute('inert')).toBe(false);
  expect(clerkRoot.querySelector('input')?.closest('[inert]')).toBeNull();
  clerkRoot.remove();
});

it('still marks #root inert when an embedded Clerk component like UserProfile lives inside the app root', async () => {
  const user = userEvent.setup();
  const appRoot = document.createElement('div');
  appRoot.id = 'root';
  document.body.appendChild(appRoot);
  const onClose = vi.fn();

  try {
    const view = (open: boolean): React.ReactElement => (
      <main>
        <button type="button">Open dialog</button>
        <div className="cl-rootBox cl-userProfile-root">
          <button type="button">Manage security</button>
        </div>
        <Dialog open={open} onOpenChange={onClose}>
          <DialogContent>
            <DialogTitle>Security confirmation</DialogTitle>
            <button type="button">Confirm</button>
          </DialogContent>
        </Dialog>
      </main>
    );
    const { rerender } = render(view(false), { container: appRoot });
    const opener = appRoot.querySelector<HTMLButtonElement>('button')!;
    opener.focus();
    rerender(view(true));

    // #root must be inert even though it contains a Clerk <UserProfile> tree.
    expect(appRoot.hasAttribute('inert')).toBe(true);
    expect(appRoot.querySelector('.cl-userProfile-root')?.closest('[inert]')).toBe(appRoot);

    // Starting a step-up must NEVER un-inert #root, while a body-level Clerk modal IS interactive.
    const releaseStepUp = beginStepUpOverlay();
    expect(appRoot.hasAttribute('inert')).toBe(true);

    const clerkPortal = document.createElement('div');
    clerkPortal.setAttribute('data-floating-ui-portal', '');
    clerkPortal.innerHTML = `
      <div class="cl-modalBackdrop">
        <div class="cl-modalContent" role="dialog" aria-modal="true" aria-label="Verification required">
          <input aria-label="Verification code" />
        </div>
      </div>
    `;
    document.body.appendChild(clerkPortal);
    await act(async () => { await Promise.resolve(); });

    expect(clerkPortal.hasAttribute('inert')).toBe(false);
    expect(appRoot.hasAttribute('inert')).toBe(true);

    clerkPortal.remove();
    releaseStepUp();

    // Embedded Clerk markup in #root must not block Escape from dismissing the dialog.
    await user.keyboard('{Escape}');
    expect(onClose).toHaveBeenCalledWith(false);
  } finally {
    appRoot.remove();
  }
});

it('never exempts a non-#root container that holds the dialog opener even if it embeds a Clerk component', () => {
  const host = document.createElement('div');
  document.body.appendChild(host);

  try {
    const view = (open: boolean): React.ReactElement => (
      <div className="cl-userProfile-root">
        <button type="button">Trigger</button>
        <Dialog open={open} onOpenChange={vi.fn()}>
          <DialogContent>
            <DialogTitle>Opener host check</DialogTitle>
            <button type="button">OK</button>
          </DialogContent>
        </Dialog>
      </div>
    );
    const { rerender } = render(view(false), { container: host });
    const opener = host.querySelector<HTMLButtonElement>('button')!;
    opener.focus();
    rerender(view(true));

    expect(host.hasAttribute('inert')).toBe(true);
    expect(host.querySelector('.cl-userProfile-root')?.closest('[inert]')).toBe(host);
  } finally {
    host.remove();
  }
});
