// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it } from 'vitest';
import type { PayPeriod } from '@/types';
import { PayRunRecordHeader } from './PayRunRecordHeader';

afterEach(cleanup);

it('keeps the parallel comparison explanation beside the payroll status', () => {
  const payRun = { id: 2, status: 'approved', parallel_run: true, start_date: '2026-09-16', end_date: '2026-09-30', pay_date: '2026-10-15', run_purpose: 'regular' } as PayPeriod;
  render(<MemoryRouter><PayRunRecordHeader payRun={payRun} returnTo="/pay-periods" attention="Parallel comparison · cannot commit" /></MemoryRouter>);
  fireEvent.click(screen.getByRole('button', { name: 'About parallel comparison' }));
  expect(screen.getByText('This run is isolated from live payroll actions. It can be calculated and reviewed, but never committed, paid, printed, or filed.')).toBeTruthy();
});
