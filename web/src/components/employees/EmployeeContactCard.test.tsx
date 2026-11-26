// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeContactCard } from './EmployeeContactCard';
import { ApiError } from '@/services/api';
import type { ContactEmployee } from '@/types';

const apiMocks = vi.hoisted(() => ({
  adminUpdate: vi.fn(),
  clientUpdate: vi.fn(),
}));

vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return {
    ...actual,
    employeesApi: { update: apiMocks.adminUpdate },
    clientEmployeesApi: { update: apiMocks.clientUpdate },
  };
});

const riley: ContactEmployee = {
  id: 42,
  company_id: 7,
  first_name: 'Riley',
  last_name: 'Santos',
  status: 'active',
  email: 'riley.old@example.net',
  phone: '+16715550100',
  address_line1: '100 Example St',
  address_line2: null,
  city: 'Hagatna',
  state: 'GU',
  zip: '96910',
  email_verified_at: '2026-11-01T00:00:00Z',
  phone_confirmed_by_employee_at: null,
  contact_source: null,
  contact_revision: 'rev-1',
  contact_details_status: { needs_contact_details: false, missing_fields: [], email_issue: null },
  updated_at: '2026-11-01T00:00:00Z',
} as unknown as ContactEmployee;

function renderCard(props: Partial<Parameters<typeof EmployeeContactCard>[0]> = {}) {
  const onSaved = vi.fn();
  const view = render(
    <MemoryRouter>
      <EmployeeContactCard employee={riley} companyId={7} audience="admin" canEdit onSaved={onSaved} {...props} />
    </MemoryRouter>,
  );
  return { ...view, onSaved };
}

const field = (label: string) => screen.getByLabelText(label) as HTMLInputElement;

beforeEach(() => {
  apiMocks.adminUpdate.mockReset();
  apiMocks.clientUpdate.mockReset();
});

afterEach(() => cleanup());

describe('EmployeeContactCard', () => {
  it('shows email, mobile and address with the confirmed badge', () => {
    renderCard();
    expect(screen.getByText('riley.old@example.net')).toBeTruthy();
    expect(screen.getByText('Email confirmed')).toBeTruthy();
    expect(screen.getByText('100 Example St')).toBeTruthy();
    expect(screen.getByText('Hagatna, GU 96910')).toBeTruthy();
  });

  it('is view-only for a Client viewer: no Edit button, and says why', () => {
    renderCard({ audience: 'client', canEdit: false, viewOnly: true });
    expect(screen.queryByRole('button', { name: /Edit contact/ })).toBeNull();
    expect(screen.queryByLabelText('Email for Riley Santos')).toBeNull();
    expect(screen.getByRole('note')).toBeTruthy();
  });

  it('ignores an outside edit request when it cannot edit', () => {
    const { rerender } = renderCard({ canEdit: false });
    rerender(
      <MemoryRouter>
        <EmployeeContactCard employee={riley} companyId={7} audience="admin" canEdit={false} editRequest={1} />
      </MemoryRouter>,
    );
    expect(screen.queryByLabelText('Email for Riley Santos')).toBeNull();
  });

  it('saves only changed fields with the revision and baseline captured at Edit (staff)', async () => {
    apiMocks.adminUpdate.mockResolvedValueOnce({
      data: { ...riley, email: 'riley.new@example.net', email_verified_at: null, contact_revision: 'rev-2' },
      contact_warnings: [],
    });
    const { onSaved } = renderCard();

    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: ' riley.new@example.net ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Riley Santos' }));

    await waitFor(() => expect(apiMocks.adminUpdate).toHaveBeenCalledTimes(1));
    expect(apiMocks.adminUpdate).toHaveBeenCalledWith(42, {
      email: 'riley.new@example.net',
      row_revision: 'rev-1',
      baseline_values: { email: 'riley.old@example.net' },
      response_view: 'contact',
    }, 7);
    expect(await screen.findByRole('status')).toBeTruthy();
    expect(screen.getByText('riley.new@example.net')).toBeTruthy();
    expect(screen.queryByText('Email confirmed')).toBeNull();
    expect(onSaved).toHaveBeenCalledWith(expect.objectContaining({ email: 'riley.new@example.net' }), { emailChanged: true });
  });

  it('opens the editor from an outside request (the Edit contact details link) and uses the client endpoint', async () => {
    apiMocks.clientUpdate.mockResolvedValueOnce({
      data: { ...riley, phone: '+16715550199', contact_revision: 'rev-2' },
      contact_warnings: [],
      change_request: null,
    });
    const { rerender } = renderCard({ audience: 'client' });
    rerender(
      <MemoryRouter>
        <EmployeeContactCard employee={riley} companyId={7} audience="client" canEdit editRequest={1} />
      </MemoryRouter>,
    );

    fireEvent.change(field('Mobile for Riley Santos'), { target: { value: '555-0199' } });
    fireEvent.keyDown(field('Mobile for Riley Santos'), { key: 'Enter' });

    await waitFor(() => expect(apiMocks.clientUpdate).toHaveBeenCalledTimes(1));
    expect(apiMocks.clientUpdate).toHaveBeenCalledWith(42, expect.objectContaining({
      phone: '555-0199', row_revision: 'rev-1', baseline_values: { phone: '+16715550100' },
    }));
    expect(apiMocks.adminUpdate).not.toHaveBeenCalled();
  });

  it('reports a coworker’s change instead of overwriting it, then keeps mine against the newer record', async () => {
    const theirs = { ...riley, email: 'coworker.set@example.net', contact_revision: 'rev-2' };
    apiMocks.adminUpdate
      .mockRejectedValueOnce(new ApiError('Someone else updated this employee while you were editing.', 409, undefined, {
        error: 'Someone else updated this employee while you were editing.',
        code: 'contact_revision_conflict',
        conflicting_fields: ['email'],
        contact_revision: 'rev-2',
        current_values: { email: 'coworker.set@example.net' },
        data: theirs,
      }))
      .mockResolvedValueOnce({ data: { ...theirs, email: 'mine@example.net', contact_revision: 'rev-3' }, contact_warnings: [] });
    renderCard();

    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: 'mine@example.net' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Riley Santos' }));

    expect(await screen.findByText('Someone else updated this employee while you were editing.')).toBeTruthy();
    expect(screen.getByText('coworker.set@example.net')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Keep yours' }));
    await waitFor(() => expect(apiMocks.adminUpdate).toHaveBeenCalledTimes(2));
    expect(apiMocks.adminUpdate).toHaveBeenLastCalledWith(42, expect.objectContaining({
      email: 'mine@example.net', row_revision: 'rev-2', baseline_values: { email: 'coworker.set@example.net' },
    }), 7);
    expect(await screen.findByText('mine@example.net')).toBeTruthy();
  });

  it('“Use theirs” shows the newer value and drops only my conflicting edit', async () => {
    const theirs = { ...riley, email: 'coworker.set@example.net', contact_revision: 'rev-2' };
    apiMocks.adminUpdate.mockRejectedValueOnce(new ApiError('Conflict', 409, undefined, {
      error: 'Someone else updated this employee while you were editing.',
      code: 'contact_revision_conflict',
      conflicting_fields: ['email'],
      contact_revision: 'rev-2',
      current_values: {},
      data: theirs,
    }));
    renderCard();

    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: 'mine@example.net' } });
    fireEvent.change(field('City for Riley Santos'), { target: { value: 'Dededo' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Riley Santos' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Use theirs' }));

    expect(field('Email for Riley Santos').value).toBe('coworker.set@example.net');
    expect(field('City for Riley Santos').value).toBe('Dededo');
  });

  it('shows the server’s plain validation message on the field', async () => {
    // The body the server sends for a malformed email.
    apiMocks.adminUpdate.mockRejectedValueOnce(new ApiError('Validation failed', 422, { email: ['must be a valid email address'] }, {
      error: 'Validation failed',
      details: { email: ['must be a valid email address'] },
      contact_validation: { same_person_confirmation_required: false, warnings: [], email_error_code: 'invalid_email' },
    }));
    renderCard();

    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: 'not-an-email' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Riley Santos' }));

    expect((await screen.findByRole('alert')).textContent).toContain("This isn't a complete email address. Check it for typos.");
    expect(field('Email for Riley Santos').value).toBe('not-an-email');
  });

  it('asks to confirm a login email belongs to this employee, then saves with the confirmation', async () => {
    apiMocks.adminUpdate
      .mockRejectedValueOnce(new ApiError('Confirm', 422, { email: ['This email belongs to an existing payroll login.'] }, {
        errors: { email: ['This email belongs to an existing payroll login.'] },
        contact_validation: { same_person_confirmation_required: true, warnings: [] },
      }))
      .mockResolvedValueOnce({ data: { ...riley, email: 'login@example.net', contact_revision: 'rev-2' }, contact_warnings: [] });
    renderCard();

    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: 'login@example.net' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Riley Santos' }));
    fireEvent.click(await screen.findByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: 'Confirm and save' }));

    await waitFor(() => expect(apiMocks.adminUpdate).toHaveBeenCalledTimes(2));
    expect(apiMocks.adminUpdate).toHaveBeenLastCalledWith(42, expect.objectContaining({
      email: 'login@example.net', confirm_same_person_email: true,
    }), 7);
  });

  it('Cancel drops edits and returns to the saved values', () => {
    renderCard();
    fireEvent.click(screen.getByRole('button', { name: 'Edit contact for Riley Santos' }));
    fireEvent.change(field('Email for Riley Santos'), { target: { value: 'typo@example.net' } });
    fireEvent.click(screen.getByRole('button', { name: 'Cancel editing Riley Santos' }));
    expect(screen.getByText('riley.old@example.net')).toBeTruthy();
    expect(apiMocks.adminUpdate).not.toHaveBeenCalled();
  });
});
