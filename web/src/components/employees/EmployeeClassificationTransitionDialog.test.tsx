// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeClassificationTransitionDialog } from './EmployeeClassificationTransitionDialog';
import type { Employee } from '@/types';

const transitionTaxClassification = vi.hoisted(() => vi.fn());

vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return { ...actual, employeesApi: { transitionTaxClassification } };
});

const employee = {
  id: 41, company_id: 7, first_name: 'Asia', last_name: 'Taylor', employment_type: 'hourly', pay_rate: 16, pay_frequency: 'biweekly',
} as Employee;

describe('EmployeeClassificationTransitionDialog', () => {
  afterEach(cleanup);

  it('tells the operator when the old email was left blank before opening the new record', async () => {
    const newEmployee = { ...employee, id: 42, employment_type: 'contractor', email: '' } as Employee;
    const notice = "The email on the old record wasn't copied, because it can't be used for this worker. Enter the worker's own email on the new record.";
    transitionTaxClassification.mockResolvedValue({ data: newEmployee, previous_employee: { id: 41, name: 'Asia Taylor' }, message: 'ok', contact_notices: [notice] });
    const onTransitioned = vi.fn();
    const onOpenChange = vi.fn();

    render(<EmployeeClassificationTransitionDialog employee={employee} open onOpenChange={onOpenChange} onTransitioned={onTransitioned} />);
    fireEvent.change(screen.getByLabelText(/Reason for transition/), { target: { value: 'Worker now invoices as a contractor' } });
    fireEvent.click(screen.getByRole('button', { name: /Create linked record/ }));

    expect(await screen.findByText(notice)).toBeTruthy();
    expect(onTransitioned).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: /Open the new record/ }));
    await waitFor(() => expect(onTransitioned).toHaveBeenCalledWith(newEmployee));
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it('opens the new record straight away when there is nothing to report', async () => {
    const newEmployee = { ...employee, id: 43, employment_type: 'contractor' } as Employee;
    transitionTaxClassification.mockResolvedValue({ data: newEmployee, previous_employee: { id: 41, name: 'Asia Taylor' }, message: 'ok', contact_notices: [] });
    const onTransitioned = vi.fn();

    render(<EmployeeClassificationTransitionDialog employee={employee} open onOpenChange={vi.fn()} onTransitioned={onTransitioned} />);
    fireEvent.change(screen.getByLabelText(/Reason for transition/), { target: { value: 'Worker now invoices as a contractor' } });
    fireEvent.click(screen.getByRole('button', { name: /Create linked record/ }));

    await waitFor(() => expect(onTransitioned).toHaveBeenCalledWith(newEmployee));
  });
});
