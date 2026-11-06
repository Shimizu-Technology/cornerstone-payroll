// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { MemoryRouter } from 'react-router';
import { FilingEmployeeWarnings } from './FilingEmployeeWarnings';

afterEach(cleanup);
it('lists every affected employee with missing fields and a company-scoped edit link', () => {
  const employees = Array.from({ length: 32 }, (_, id) => ({ employee_id: id + 1, name: `Worker ${id + 1}`, missing_fields: ['ssn', 'address'] as ('ssn' | 'address')[], edit_path: `/companies/42/employees/${id + 1}/edit` }));
  render(<MemoryRouter><FilingEmployeeWarnings completeness={{ employees, missing_ssn_count: 32, missing_address_count: 32, message: 'Add missing details before filing. Drafts can still be generated.' }} /></MemoryRouter>);
  expect(screen.getByText('Worker 32 — missing 9-digit SSN and complete address')).toBeTruthy();
  expect(screen.getAllByRole('link')).toHaveLength(32);
  expect(screen.getByRole('link', { name: 'Edit profile for Worker 32 (opens in a new tab)' }).getAttribute('href')).toBe('/companies/42/employees/32/edit');
  expect(screen.getByText(/Drafts can still be generated/)).toBeTruthy();
});
it('has no warning after employee details are complete', () => {
  render(<FilingEmployeeWarnings completeness={{ employees: [], missing_ssn_count: 0, missing_address_count: 0, message: null }} />);
  expect(screen.queryByRole('region')).toBeNull();
});
it('keeps the preview warning compact with an expandable employee list', () => {
  render(<MemoryRouter><FilingEmployeeWarnings compact completeness={{ employees: [{ employee_id: 1, name: 'Synthetic Worker', missing_fields: ['ssn'], edit_path: '/companies/42/employees/1/edit' }], missing_ssn_count: 1, missing_address_count: 0, message: 'Details missing' }} /></MemoryRouter>);
  expect(screen.getByText(/Missing details print blank/)).toBeTruthy();
  expect(screen.getByText('Review affected employees (1)')).toBeTruthy();
});
