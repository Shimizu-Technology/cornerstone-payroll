// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Dialog, DialogContent, DialogTitle } from './dialog';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

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
