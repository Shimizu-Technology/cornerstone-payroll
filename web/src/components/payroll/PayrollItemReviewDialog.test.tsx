// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { useState } from 'react';
import { PayrollDetailBoundary } from './PayrollItemReviewDialog';
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
it('contains a detail rendering failure and retries without losing the surrounding worksheet', () => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
  function FailedDetail(): never { throw new Error('Dynamic import unavailable'); }
  function Worksheet() {
    const [attempt, setAttempt] = useState(0);
    return <><input aria-label="Unsaved hours" defaultValue="4" />
      <PayrollDetailBoundary key={attempt} onRetry={() => setAttempt(1)}>
        {attempt ? <p>Recovered saved details</p> : <FailedDetail />}
      </PayrollDetailBoundary></>;
  }
  render(<Worksheet />);
  fireEvent.change(screen.getByRole('textbox', { name: 'Unsaved hours' }), { target: { value: '7.5' } });
  expect(screen.getByRole('alert').textContent).toContain('Your worksheet entries are still here');
  fireEvent.click(screen.getByRole('button', { name: 'Retry details' }));
  expect(screen.getByText('Recovered saved details')).toBeTruthy();
  expect((screen.getByRole('textbox', { name: 'Unsaved hours' }) as HTMLInputElement).value).toBe('7.5');
});
