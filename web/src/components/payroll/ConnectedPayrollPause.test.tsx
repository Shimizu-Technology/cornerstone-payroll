// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { AirePayrollCockpit } from './AirePayrollCockpit';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import type { AirePayrollCalendarState } from '@/types';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1 } }) }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => true }));
afterEach(cleanup);
const calendar = { enabled: true, source_id: 1, source_name: 'AIRE', can_publish: false, can_retry: false,
  connected_payroll: { mode: 'paused', enabled: false, message: 'Connected payroll is paused' } } as AirePayrollCalendarState;

it('disables source locking with a plain-language pause message', () => {
  render(<MemoryRouter><AirePayrollCockpit payPeriodId={1} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByRole('status').textContent).toContain('Connected payroll is paused');
  expect((screen.getByRole('button', { name: 'Lock eligible time' }) as HTMLButtonElement).disabled).toBe(true);
});

it('holds publication without displaying a cutoff countdown', () => {
  render(<MemoryRouter><AirePayrollCalendarCard payPeriodId={1} calendar={calendar} onRefresh={vi.fn()} /></MemoryRouter>);
  expect(screen.getByRole('status').textContent).toBe('Connected payroll is paused');
  expect((screen.getByRole('button', { name: 'Publish to time tracking' }) as HTMLButtonElement).disabled).toBe(true);
});

it('preserves the local manual source coverage review while connected controls are paused', () => {
  const review = vi.fn();
  render(<MemoryRouter><AirePayrollCockpit payPeriodId={1} calendar={calendar} onRefresh={vi.fn()}
    sourceCoverageRequired sourceCoverageAction={<button onClick={review}>Review source coverage</button>} /></MemoryRouter>);
  fireEvent.click(screen.getByRole('button', { name: 'Review source coverage' }));
  expect(review).toHaveBeenCalledOnce();
  expect((screen.getByRole('button', { name: 'Lock eligible time' }) as HTMLButtonElement).disabled).toBe(true);
});
