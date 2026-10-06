// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router';
import { ActionFeedback, FeedbackProvider, useFeedback } from './action-feedback';
import { Dialog, DialogContent, DialogTitle } from './dialog';

afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

function NotifyButton({ tone = 'error' }: { tone?: 'error' | 'success' }) {
  const { notify } = useFeedback();
  return <button onClick={() => notify({ tone, message: 'Saved action result' })}>Notify</button>;
}

describe('shared action feedback', () => {
  it('deduplicates simple sources without republishing dismissed errors on rerender', () => {
    const view = () => <FeedbackProvider><ActionFeedback tone="error" message="Could not save" /><ActionFeedback tone="error" message="Could not save" /></FeedbackProvider>;
    const { rerender } = render(view());
    expect(screen.getAllByRole('alert')).toHaveLength(1);
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss notification: Could not save' }));
    rerender(view());
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('preserves separate forms rich recovery content and ignores changing child identity', () => {
    const view = (detail: string) => <FeedbackProvider><ActionFeedback tone="error" message="Could not save"><button>{detail}</button></ActionFeedback><ActionFeedback tone="error" message="Could not save"><a href="/review">Review the other form</a></ActionFeedback></FeedbackProvider>;
    const { rerender } = render(view('Retry first form'));
    expect(screen.getAllByRole('alert')).toHaveLength(2);
    rerender(view('Retry updated first form'));
    expect(screen.getAllByRole('alert')).toHaveLength(2);
    expect(screen.getByRole('button', { name: 'Retry updated first form' })).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Review the other form' })).toBeTruthy();
  });

  it('replaces a previous imperative failure with the successful retry result', () => {
    function Retry() {
      const { notify } = useFeedback();
      return <><button onClick={() => notify({ tone: 'error', message: 'Could not save' })}>Fail</button><button onClick={() => notify({ tone: 'success', message: 'Saved successfully' })}>Retry</button></>;
    }
    render(<FeedbackProvider><Retry /></FeedbackProvider>);
    fireEvent.click(screen.getByRole('button', { name: 'Fail' }));
    expect(screen.getByRole('alert')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.getByRole('status').textContent).toContain('Saved successfully');
  });

  it('ignores a stale notification callback after company switch without discarding new-company feedback', () => {
    let latestNotify: ReturnType<typeof useFeedback>['notify'] | undefined;
    function Capture() { latestNotify = useFeedback().notify; return null; }
    const view = (scope: string) => <FeedbackProvider scopeKey={scope}><Capture /></FeedbackProvider>;
    const { rerender } = render(view('company6'));
    const staleNotify = latestNotify;
    rerender(view('company7'));
    act(() => latestNotify?.({ tone: 'success', message: 'New company saved' }));
    act(() => staleNotify?.({ tone: 'error', message: 'Old company failed late' }));
    expect(screen.getByRole('status').textContent).toContain('New company saved');
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('keeps errors until dismissal or resolution, and permits the same error on a subsequent retry', () => {
    vi.useFakeTimers();
    const view = (message: string) => <FeedbackProvider>{message && <ActionFeedback tone="error" message={message} />}</FeedbackProvider>;
    const { rerender } = render(view('Could not save'));
    act(() => vi.advanceTimersByTime(60_000));
    expect(screen.getByRole('alert').textContent).toContain('Could not save');
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss notification: Could not save' }));
    rerender(view(''));
    rerender(view('Could not save'));
    expect(screen.getByRole('alert').textContent).toContain('Could not save');
    rerender(view(''));
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('preserves a successful save across navigation and expires it after ten readable seconds', () => {
    vi.useFakeTimers();
    function SavePage() {
      const { notify } = useFeedback();
      const navigate = useNavigate();
      return <button onClick={() => { notify({ tone: 'success', message: 'Employee updated.' }); navigate('/employee'); }}>Save employee</button>;
    }
    render(<MemoryRouter><FeedbackProvider><Routes><Route path="/" element={<SavePage />} /><Route path="/employee" element={<p>Employee record</p>} /></Routes></FeedbackProvider></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: 'Save employee' }));
    expect(screen.getByText('Employee record')).toBeTruthy();
    const toast = screen.getByRole('status');
    act(() => vi.advanceTimersByTime(4_000));
    fireEvent.mouseEnter(toast);
    act(() => vi.advanceTimersByTime(20_000));
    expect(screen.getByRole('status').textContent).toContain('Employee updated.');
    fireEvent.mouseLeave(toast);
    const close = screen.getByRole('button', { name: 'Dismiss notification: Employee updated.' });
    fireEvent.focus(close);
    act(() => vi.advanceTimersByTime(20_000));
    expect(screen.getByRole('status')).toBeTruthy();
    fireEvent.blur(close);
    act(() => vi.advanceTimersByTime(5_999));
    expect(screen.getByRole('status')).toBeTruthy();
    act(() => vi.advanceTimersByTime(1));
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('retains a declarative success when its source unmounts', () => {
    const view = (visible: boolean) => <FeedbackProvider>{visible && <ActionFeedback tone="success" message="Settings saved." />}</FeedbackProvider>;
    const { rerender } = render(view(true));
    rerender(view(false));
    expect(screen.getByRole('status').textContent).toContain('Settings saved.');
  });

  it('clears feedback when changing company or signing out', () => {
    const view = (scope: string) => <FeedbackProvider key={scope} scopeKey={scope}><NotifyButton /></FeedbackProvider>;
    const { rerender } = render(view('leon:company6'));
    fireEvent.click(screen.getByRole('button', { name: 'Notify' }));
    expect(screen.getByRole('alert')).toBeTruthy();
    rerender(view('leon:company7'));
    expect(screen.queryByRole('alert')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Notify' }));
    rerender(view('signed-out'));
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('keeps modal errors outside inert background, announces them, and includes dismiss in the modal keyboard cycle', () => {
    vi.useFakeTimers();
    vi.spyOn(HTMLElement.prototype, 'offsetParent', 'get').mockImplementation(function (this: HTMLElement) { return this.parentElement; });
    render(<FeedbackProvider><Dialog open onOpenChange={() => undefined}><DialogContent><DialogTitle>Save profile</DialogTitle><NotifyButton /><button>Cancel</button></DialogContent></Dialog></FeedbackProvider>);
    act(() => vi.advanceTimersByTime(20));
    const notify = screen.getByRole('button', { name: 'Notify' });
    notify.focus();
    fireEvent.click(notify);
    expect(document.activeElement).toBe(notify);
    expect(document.querySelector('[data-feedback-portal]')?.hasAttribute('inert')).toBe(false);
    expect(screen.getByRole('alert').textContent).toContain('Saved action result');
    const cancel = screen.getByRole('button', { name: 'Cancel' });
    cancel.focus();
    fireEvent.keyDown(cancel, { key: 'Tab' });
    const dismiss = screen.getByRole('button', { name: 'Dismiss notification: Saved action result' });
    expect(document.activeElement).toBe(dismiss);
    fireEvent.keyDown(dismiss, { key: 'Tab' });
    expect(document.activeElement).toBe(notify);
    dismiss.focus();
    fireEvent.click(dismiss);
    expect(document.activeElement).toBe(screen.getByRole('dialog'));
  });

  it('preserves the original message and adds recovery steps; standalone components have an inline fallback', () => {
    const { unmount } = render(<FeedbackProvider><ActionFeedback tone="error" message="New-hire documents are missing" /></FeedbackProvider>);
    expect(screen.getByRole('alert').textContent).toContain('New-hire documents are missing');
    expect(screen.getByRole('alert').textContent).toContain('Manage documents');
    unmount();
    render(<ActionFeedback tone="error" message="Could not save">Source detail</ActionFeedback>);
    expect(screen.getByRole('alert').textContent).toBe('Source detail');
  });
});
