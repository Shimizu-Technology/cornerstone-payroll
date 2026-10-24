// @vitest-environment jsdom
import * as React from 'react';
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import userEvent from '@testing-library/user-event';
import { NumericInput } from './numeric-input';
import { Dialog, DialogContent, DialogTitle } from './dialog';

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
  const view = (open: boolean) => <Dialog open={open} onOpenChange={changed}><DialogContent><DialogTitle>Review</DialogTitle><button>Confirm</button></DialogContent></Dialog>;
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
  const view = (open: boolean) => <><button ref={opener}>Open PDF</button><button autoFocus>Other action</button>
    <Dialog open={open} onOpenChange={vi.fn()} returnFocusRef={opener}><DialogContent><DialogTitle>PDF</DialogTitle><button>Close PDF</button></DialogContent></Dialog></>;
  const { rerender } = render(view(false));
  rerender(view(true));
  rerender(view(false));
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  expect(document.activeElement).toBe(opener.current);
});


it('finishes a focused numeric draft before reopening with reset values', async () => {
  function Entry({ open }: { open: boolean }) {
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
