// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it } from 'vitest';
import type { ComponentProps } from 'react';
import { NewHireDocumentsNotice } from './NewHireDocumentsNotice';
import { PayRunFeedback } from './PayRunFeedback';

const gaps = [
  { employee_id: 11, employee_name: 'Juniper Moss', missing: ['Identity and work authorization', 'Signed withholding election'] },
  { employee_id: 12, employee_name: 'Rowan Pike', missing: ['Signed withholding election'] },
];
const returnTo = '/companies/3/pay-runs/9/work';
afterEach(cleanup);

it('lists each new hire with a link to their documents before approval', () => {
  render(<MemoryRouter><NewHireDocumentsNotice gaps={gaps} companyId={3} returnTo={returnTo} status="calculated" /></MemoryRouter>);
  expect(screen.getByRole('heading', { name: 'New-hire documents needed before approving' })).toBeTruthy();
  expect(screen.getByText('Juniper Moss').parentElement?.textContent).toContain('Identity and work authorization, Signed withholding election');
  expect(screen.getByRole('link', { name: 'Upload or verify documents for Rowan Pike' }).getAttribute('href'))
    .toBe('/companies/3/employees/12/edit?return_to=%2Fcompanies%2F3%2Fpay-runs%2F9%2Fwork#employee-documents');
});

it('says commit once the run is approved and hides when nothing is needed', () => {
  const { rerender } = render(<MemoryRouter><NewHireDocumentsNotice gaps={gaps} companyId={3} returnTo={returnTo} status="approved" /></MemoryRouter>);
  expect(screen.getByRole('heading', { name: 'New-hire documents needed before committing' })).toBeTruthy();
  rerender(<MemoryRouter><NewHireDocumentsNotice gaps={[]} companyId={3} returnTo={returnTo} status="calculated" /></MemoryRouter>);
  expect(screen.queryByRole('heading')).toBeNull();
});

it('links the blocked employees from the Approve error', () => {
  const props = {
    calculationFailures: [], calculationNotice: null, calendarRefreshError: null, companyId: 3, currentPath: returnTo,
    documentBlockedEmployees: [gaps[0]], employees: [], error: 'Resolve required new-hire documents before approving or committing payroll: Juniper Moss: Signed withholding election (missing).',
    payPeriod: { id: 9, pay_date: '2026-11-20' }, payrollItems: [], processing: false, reloadSavedSourceImport: async () => {},
    savedImportReloadRequired: false, timeTrackingImportOpen: false, worksheetRefreshWarning: null,
  } as unknown as ComponentProps<typeof PayRunFeedback>;
  render(<MemoryRouter><PayRunFeedback {...props} /></MemoryRouter>);
  const alert = screen.getByRole('alert');
  expect(within(alert).getByText("Payroll can't be approved until these new-hire documents are verified or waived.")).toBeTruthy();
  expect(within(alert).getByRole('link', { name: 'Upload or verify documents for Juniper Moss' }).getAttribute('href')).toContain('/companies/3/employees/11/edit');
});
