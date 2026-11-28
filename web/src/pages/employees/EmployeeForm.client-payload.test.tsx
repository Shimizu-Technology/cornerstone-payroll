// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within, type RenderResult } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';
import { ApiError, apiErrorMessage } from '@/services/api';

const mocks = vi.hoisted(() => ({ get: vi.fn(), create: vi.fn(), update: vi.fn(), departments: vi.fn(), refresh: vi.fn(), intake: vi.fn(), viewer: false, company: undefined as Record<string, unknown> | undefined }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { company_id: 1, role: 'client' }, isClient: true, isClientViewer: mocks.viewer, isSuperAdmin: false, isManager: false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ refreshCompanies: mocks.refresh, activeCompanyId: 1, activeCompany: mocks.company }) }));
vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({ useEmployeeIntakeSettings: mocks.intake }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({ EmployeeClassificationTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeStatusTransitionDialog', () => ({ EmployeeStatusTransitionDialog: () => null }));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, clientEmployeesApi: { ...actual.clientEmployeesApi, get: mocks.get, update: mocks.update, create: mocks.create },
    clientDepartmentsApi: { ...actual.clientDepartmentsApi, list: mocks.departments } };
});

const base = { pay_frequency: 'biweekly', filing_status: 'single', allowances: 0, additional_withholding: 0, w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2026,
  w4_effective_on: '2026-01-01', w4_signed_on: null, w4_source_reference: '', hire_date: '2025-01-01', ssn_last_four: '6789',
  address_line1: '100 Synthetic Lane', city: 'Hagåtña', state: 'GU', zip: '96910', status: 'active',
  default_payroll_adjustments: [], default_custom_earnings: [], wage_rates: [] };
const hourly = { ...base, id: 7, first_name: 'Lino', last_name: 'Quinata', employment_type: 'hourly', salary_type: 'annual', pay_rate: 12,
  contractor_type: null, contractor_pay_type: null, business_name: null };
const business = { ...base, id: 8, first_name: 'Tano', last_name: 'Builders', employment_type: 'contractor', pay_rate: 500,
  contractor_type: 'business', contractor_pay_type: 'flat_fee', business_name: 'Tano Builders LLC', ssn_last_four: null,
  contractor_ein_last_four: '4321' };

function view(id?: number): RenderResult {
  return render(<MemoryRouter initialEntries={[id ? `/companies/1/employees/${id}/edit` : '/companies/1/employees/new']}><Routes>
    <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
    <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
    <Route path="*" element={<p>Left the form</p>} />
  </Routes></MemoryRouter>);
}
function submit(): void { fireEvent.submit(document.getElementById('employee-form')!); }

beforeEach(() => {
  vi.clearAllMocks();
  mocks.company = undefined;
  mocks.viewer = false;
  mocks.refresh.mockResolvedValue(undefined);
  mocks.intake.mockReturnValue({ settings: { enabled: false }, loading: false });
  mocks.departments.mockResolvedValue({ data: [] });
  mocks.update.mockResolvedValue({ data: hourly, change_request: null, message: 'Saved' });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

describe('Client employee form payload', () => {
  it('keeps approval-first entry fields and validation when the mode is locked', async () => {
    mocks.company = { id: 1, active: true, employee_lifecycle_mode: 'approval_first' };
    view();
    expect((screen.getByLabelText('How this employee is paid') as HTMLSelectElement).disabled).toBe(true);
    expect(screen.queryByText(/save with just a name/)).toBeNull();
    expect(screen.queryByLabelText('Record a received W-4')).toBeNull();
    expect(screen.getByRole('button', { name: 'Create Employee' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Rowan' } });
    fireEvent.change(screen.getByLabelText(/Last Name/), { target: { value: 'Fixture' } });
    submit();
    expect(await screen.findByText('Social Security Number is required')).toBeTruthy();
    expect(mocks.create).not.toHaveBeenCalled();
  });

  it('creates a partial client-managed hire without recording a default payment method or W-4', async () => {
    mocks.company = { id: 1, active: true, employee_lifecycle_mode: 'client_managed' };
    mocks.create.mockResolvedValue({ data: hourly, message: 'Saved as Incomplete' });
    mocks.get.mockResolvedValue({ data: hourly });
    view();
    fireEvent.change(screen.getByLabelText(/First Name/), { target: { value: 'Rowan' } });
    fireEvent.change(screen.getByLabelText(/Last Name/), { target: { value: 'Fixture' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save employee' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledOnce());
    const [payload] = mocks.create.mock.calls[0];
    expect(payload).toMatchObject({ first_name: 'Rowan', last_name: 'Fixture', employment_type: 'hourly' });
    for (const field of ['payment_delivery_method', 'wage_rates', 'filing_status', 'w4_effective_on', 'w4_election_received', 'ssn', 'ssn_confirmation']) {
      expect(payload[field]).toBeUndefined();
    }
  });

  it('sends an effective-dated rate, an explicitly received W-4 and confirmed SSN to the client endpoint', async () => {
    mocks.company = { id: 1, active: true, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: {
      ...hourly,
      readiness: { status: 'missing_items', rates_on: '2026-12-06', w4_on: '2026-12-11', items: [] },
      lifecycle_edit_context: { own_record: false, compensation_default_on: '2026-11-30' },
    } });
    view(7);
    expect(await screen.findByText(/This employee can still be paid/)).toBeTruthy();
    fireEvent.change(screen.getByLabelText('How this employee is paid'), { target: { value: 'direct_deposit' } });
    expect(screen.getByText(/Cornerstone will confirm bank setup/)).toBeTruthy();
    fireEvent.change(screen.getByLabelText(/Hourly Rate/), { target: { value: '15.75' } });
    expect(screen.getByText('This pay change starts on Nov 30, 2026.')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Pay change effective date'), { target: { value: '2026-12-07' } });
    fireEvent.click(screen.getByLabelText('Record a received W-4'));
    expect((screen.getByLabelText(/^Effective date/) as HTMLInputElement).value).toBe('2026-12-11');
    fireEvent.change(screen.getByLabelText(/Source document/), { target: { value: 'Synthetic signed form' } });
    const ssn = document.querySelector<HTMLInputElement>('[name="ssn"]')!;
    expect(ssn.type).toBe('password');
    fireEvent.change(ssn, { target: { value: '900112233' } });
    expect(screen.getByText(/corrected W-2/)).toBeTruthy();
    submit();
    expect(mocks.update).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText(/Re-enter Social Security Number/), { target: { value: '900112233' } });
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(7, expect.objectContaining({
      compensation_effective_on: '2026-12-07', pay_rate: 15.75, payment_delivery_method: 'direct_deposit',
      w4_effective_on: '2026-12-11', w4_election_received: true, w4_source_reference: 'Synthetic signed form',
      ssn: '900-11-2233', ssn_confirmation: '900-11-2233',
    })));
  });

  it('explains who reviews pay changes on the manager’s own record', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: { ...hourly, lifecycle_edit_context: { own_record: true } } });
    view(7);
    expect(await screen.findByText(/payment method, name, birth date, hire date, or email go to Cornerstone for review/)).toBeTruthy();
    fireEvent.change(screen.getByLabelText(/Hourly Rate/), { target: { value: '15.75' } });
    expect(screen.getByText('Cornerstone will review when the new pay rate should take effect.')).toBeTruthy();
    expect(screen.queryByLabelText('Pay change effective date')).toBeNull();
  });

  it('keeps the draft and requires another save when the API switches the company mode', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'approval_first' };
    mocks.get.mockResolvedValue({ data: hourly });
    mocks.update.mockRejectedValueOnce(new ApiError('Company mode changed', 409, undefined, {
      code: 'lifecycle_mode_changed', employee_lifecycle_mode: 'client_managed',
    }));
    view(7);
    await screen.findByText(/Saved SSN ending in/);
    fireEvent.change(screen.getByLabelText('Job Title'), { target: { value: 'Fixture coordinator' } });
    submit();
    expect(await screen.findByText(/Your entries are still here/)).toBeTruthy();
    expect((screen.getByLabelText('Job Title') as HTMLInputElement).value).toBe('Fixture coordinator');
    expect((screen.getByLabelText('How this employee is paid') as HTMLSelectElement).disabled).toBe(false);
    expect(mocks.update).toHaveBeenCalledTimes(1);
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(2));
    expect(mocks.update.mock.calls[1][1].w4_effective_on).toBeUndefined();
  });

  it('shows the dated W-4, keeps evidence across toggles, and blocks a cleared effective date', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: {
      ...hourly, w4_signed_on: '2025-12-28', w4_source_reference: 'Fixture W-4',
      current_w4_election: {
        effective_on: '2026-01-01', w4_form_version: 2026, source: 'client_direct',
        filing_status: 'married', additional_withholding: 42, w4_dependent_credit: 0,
        w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0,
      },
      readiness: { status: 'ready', rates_on: '2026-11-28', w4_on: '2026-12-04', items: [] },
      lifecycle_edit_context: { own_record: false, approved_pay_date: '2026-12-05' },
    } });
    view(7);
    expect(await screen.findByText('Current employee election')).toBeTruthy();
    expect(screen.getByText('Effective Jan 1, 2026 · Form 2026')).toBeTruthy();
    expect(screen.getByText('$42.00')).toBeTruthy();
    expect(screen.getByText(/married filing jointly/i)).toBeTruthy();

    const received = screen.getByLabelText('Record a received W-4');
    fireEvent.click(received);
    const signed = screen.getByLabelText('Signed date on source W-4') as HTMLInputElement;
    const source = screen.getByLabelText('Source document / reference') as HTMLInputElement;
    expect(signed.value).toBe('2025-12-28');
    expect(source.value).toBe('Fixture W-4');
    fireEvent.change(source, { target: { value: 'Replacement fixture' } });
    const effective = screen.getByLabelText(/^Effective date/) as HTMLInputElement;
    expect(effective.value).toBe('2026-12-04');
    expect(screen.getByText(/reopen any approved payroll/)).toBeTruthy();
    fireEvent.change(effective, { target: { value: '' } });
    expect(screen.queryByText(/reopen any approved payroll/)).toBeNull();
    fireEvent.click(received);
    fireEvent.click(received);
    expect((screen.getByLabelText(/^Effective date/) as HTMLInputElement).value).toBe('');
    expect((screen.getByLabelText('Source document / reference') as HTMLInputElement).value).toBe('Replacement fixture');
    submit();
    expect(await screen.findByText('Enter the date this W-4 became effective')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('shows and focuses the DOB error, and does not allow clearing saved filing fields', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: {
      ...hourly, date_of_birth: '1992-05-01', hire_date: '2090-01-01', city: '',
      readiness: { status: 'incomplete', rates_on: '2026-11-28', w4_on: '2026-12-04', items: [
        { key: 'hire_date', applicable: true, complete: false }, { key: 'home_address', applicable: true, complete: false },
      ] },
    } });
    view(7);
    expect(await screen.findByText(/Required before this employee can be paid/)).toBeTruthy();
    const dob = screen.getByLabelText('Date of Birth');
    fireEvent.change(dob, { target: { value: '2090-01-02' } });
    submit();
    expect(await screen.findByText('Date of birth must be in the past')).toBeTruthy();
    expect(dob.getAttribute('aria-invalid')).toBe('true');
    await waitFor(() => expect(document.activeElement).toBe(dob));

    fireEvent.change(dob, { target: { value: '' } });
    fireEvent.change(screen.getByLabelText(/Hire Date/), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText(/Address Line 1/), { target: { value: '' } });
    submit();
    expect(await screen.findByText('Date of birth is required')).toBeTruthy();
    expect(screen.getByText('Hire date is required')).toBeTruthy();
    expect(screen.getByText('Address line 1 is required')).toBeTruthy();
    expect(screen.queryByText('City is required')).toBeNull();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('prevents clearing a saved legal business name', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: business });
    view(8);
    const name = await screen.findByLabelText(/Legal Business Name/);
    fireEvent.change(name, { target: { value: '' } });
    submit();
    expect(await screen.findByText('Legal business name is required')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('shows each API validation detail once in the summary and wires payment errors to the field', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: hourly });
    const details = { payment_delivery_method: ['Cornerstone needs to reopen this payroll.'], base: ['Review the employee record.'] };
    mocks.update.mockRejectedValueOnce(new ApiError(apiErrorMessage({ error: 'Validation failed', details }, 422), 422, details));
    view(7);
    const payment = await screen.findByLabelText('How this employee is paid');
    fireEvent.change(payment, { target: { value: 'direct_deposit' } });
    submit();
    const summary = await screen.findByRole('alert');
    expect(summary.textContent?.match(/Cornerstone needs to reopen this payroll/g)).toHaveLength(1);
    expect(summary.textContent?.match(/Review the employee record/g)).toHaveLength(1);
    expect(summary.textContent).not.toContain('base:');
    expect(payment.getAttribute('aria-invalid')).toBe('true');
    expect(document.getElementById(payment.getAttribute('aria-describedby')!)?.textContent).toContain('Cornerstone needs to reopen this payroll.');
    await waitFor(() => expect(document.activeElement).toBe(payment));
  });

  it('keeps the approval-first edit form dormant despite persisted readiness', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'approval_first' };
    mocks.get.mockResolvedValue({ data: {
      ...hourly, w4_effective_on: null, readiness_gate_enforced: true,
      readiness: { status: 'incomplete', rates_on: '2026-11-28', w4_on: '2026-12-04', items: [] },
    } });
    view(7);
    expect(await screen.findByRole('button', { name: 'Update Employee' })).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Pay setup' })).toBeNull();
    expect(screen.queryByLabelText('Record a received W-4')).toBeNull();
    expect((screen.getByLabelText('How this employee is paid') as HTMLSelectElement).disabled).toBe(true);
    const ssn = screen.getByLabelText(/^Social Security Number/) as HTMLInputElement;
    expect(ssn.type).toBe('text');
    expect(ssn.value).toBe('');
    expect(screen.getByText(/submit a replacement for approval/)).toBeTruthy();
    submit();
    expect(await screen.findByText('Enter the date this W-4 became effective')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('blocks edit-mode writes for a client viewer', async () => {
    mocks.viewer = true;
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: hourly });
    view(7);
    const section = await screen.findByRole('region', { name: 'Read-only employee access' });
    expect(within(section).getByRole('link', { name: 'Back to employee records' })).toBeTruthy();
    expect(screen.queryByLabelText(/First Name/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'Save employee' })).toBeNull();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('disables intake requests after activation and returns to approval-first on a later refresh', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'approval_first' };
    mocks.get.mockResolvedValue({ data: hourly });
    mocks.update.mockRejectedValueOnce(new ApiError('Mode changed', 409, undefined, {
      code: 'lifecycle_mode_changed', employee_lifecycle_mode: 'client_managed',
    }));
    const rendered = view(7);
    const payment = await screen.findByLabelText('How this employee is paid') as HTMLSelectElement;
    await screen.findByText(/Saved SSN ending in/);
    submit();
    await screen.findByText(/Your entries are still here/);
    expect(payment.disabled).toBe(false);
    expect(mocks.intake).toHaveBeenLastCalledWith(1, true, false);
    const rerender = () => rendered.rerender(
      <MemoryRouter initialEntries={['/companies/1/employees/7/edit']}><Routes>
        <Route path="/companies/:companyId/employees/new" element={<EmployeeForm />} />
        <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
        <Route path="*" element={<p>Left the form</p>} />
      </Routes></MemoryRouter>,
    );
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    rerender();
    expect(payment.disabled).toBe(false);
    mocks.company = { id: 1, employee_lifecycle_mode: 'approval_first' };
    rerender();
    expect(payment.disabled).toBe(true);
    expect(mocks.intake).toHaveBeenLastCalledWith(1, true, true);
  });

  it('blocks a locked effective date before saving and explains negative scalar pay', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: { ...business, lifecycle_edit_context: {
      own_record: false, compensation_default_on: '2026-11-30', earliest_compensation_effective_on: '2026-11-30',
    } } });
    view(8);
    const rate = await screen.findByLabelText(/Flat Fee/);
    fireEvent.change(rate, { target: { value: '-5' } });
    submit();
    expect(await screen.findByText('Pay rate cannot be negative')).toBeTruthy();
    fireEvent.change(rate, { target: { value: '550' } });
    const date = await screen.findByLabelText('Pay change effective date') as HTMLInputElement;
    expect(date.min).toBe('2026-11-30');
    fireEvent.change(date, { target: { value: '2026-11-29' } });
    submit();
    expect(await screen.findByText('Choose Nov 30, 2026 or later. Earlier payroll is already approved or finalized.')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('masks nine-digit references and both SSN entries in client-managed mode', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: { ...hourly, w4_source_reference: 'Fixture 900112233 and 00-0004321' } });
    view(7);
    fireEvent.click(await screen.findByLabelText('Record a received W-4'));
    expect((screen.getByLabelText('Source document / reference') as HTMLInputElement).value).toBe('Fixture •••-••-2233 and ••-•••4321');
    const ssn = document.querySelector<HTMLInputElement>('[name="ssn"]')!;
    fireEvent.change(ssn, { target: { value: '900112233' } });
    expect(ssn.type).toBe('password');
    expect((screen.getByLabelText(/Re-enter Social Security Number/) as HTMLInputElement).type).toBe('password');
    expect(screen.queryByText('900-11-2233')).toBeNull();
  });

  it('keeps a long reference intact while typing and saves the raw value', async () => {
    mocks.company = { id: 1, employee_lifecycle_mode: 'client_managed' };
    mocks.get.mockResolvedValue({ data: { ...hourly, w4_source_reference: 'Fixture 900112233' } });
    view(7);
    fireEvent.click(await screen.findByLabelText('Record a received W-4'));
    const reference = screen.getByLabelText('Source document / reference') as HTMLInputElement;
    fireEvent.focus(reference);
    expect(reference.value).toBe('Fixture 900112233');
    let typed = '';
    for (const char of 'Ref 12345678901') {
      typed += char;
      fireEvent.change(reference, { target: { value: typed } });
    }
    expect(reference.value).toBe('Ref 12345678901');
    fireEvent.blur(reference);
    expect(reference.value).not.toContain('•');
  });

  it('offers the department picker and saves a practice client profile without staff payroll permission', async () => {
    mocks.company = { id: 1, active: true, test_workspace: true, practice_portal: true, workspace_can_write: false };
    mocks.get.mockResolvedValue({ data: hourly });
    mocks.departments.mockResolvedValue({ data: [{ id: 3, name: 'Practice kitchen', active: true }] });
    view(7);
    const department = await screen.findByLabelText('Department');
    await screen.findByRole('option', { name: 'Practice kitchen' });
    fireEvent.change(department, { target: { value: '3' } });
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(7, expect.objectContaining({ department_id: 3 })));
    expect(screen.queryByText('Employee details are read-only')).toBeNull();
  });

  it.each(['test_workspace_read_only', 'test_workspace_expired', 'test_workspace_archived_at', 'test_workspace_sealed_at'])('keeps a closed practice profile read-only for %s', key => {
    mocks.company = { id: 1, practice_portal: true, [key]: key.endsWith('_at') ? '2026-11-13' : true };
    mocks.get.mockResolvedValue({ data: hourly });
    view(7);
    expect(screen.getByText('Employee details are read-only')).toBeTruthy();
    expect(mocks.update).not.toHaveBeenCalled();
  });

  it('leaves contractor defaults out of a W-2 worker update', async () => {
    mocks.get.mockResolvedValue({ data: hourly });
    view(7);
    await waitFor(() => expect(document.querySelector<HTMLInputElement>('[name="city"]')?.value).toBe('Hagåtña'));
    fireEvent.change(document.querySelector('[name="city"]')!, { target: { value: 'Tamuning' } });
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    const payload = mocks.update.mock.calls[0][1];
    expect(payload.city).toBe('Tamuning');
    for (const key of ['contractor_type', 'contractor_pay_type', 'business_name', 'contractor_ein', 'w9_on_file']) {
      expect(payload[key]).toBeUndefined();
    }
  });

  it.each(['approval_first', 'client_managed'] as const)('keeps a blank EIN without exposing the saved number in %s mode', async (mode) => {
    mocks.company = { id: 1, employee_lifecycle_mode: mode };
    mocks.get.mockResolvedValue({ data: business });
    mocks.update.mockResolvedValue({ data: business, change_request: null, message: 'Saved' });
    view(8);
    expect(await screen.findByText(/Saved EIN ending in 4321/)).toBeTruthy();
    const ein = document.querySelector<HTMLInputElement>('[name="contractor_ein"]')!;
    expect(ein.value).toBe('');
    expect(ein.type).toBe(mode === 'client_managed' ? 'password' : 'text');
    expect(ein.placeholder).toContain('4321');
    expect(ein.required).toBe(false);
    expect(screen.getByText(mode === 'client_managed' ? /Enter the new number to replace it/ : /submit a replacement for approval/)).toBeTruthy();
    submit();
    await waitFor(() => expect(mocks.update).toHaveBeenCalled());
    const payload = mocks.update.mock.calls[0][1];
    expect(payload.contractor_ein).toBeUndefined();
    expect(payload.contractor_type).toBe('business');
  });
});
