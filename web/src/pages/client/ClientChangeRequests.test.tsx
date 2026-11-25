// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ApiError } from '@/services/api';
import type { EmployeeChangeRequest } from '@/services/api';
import { ClientChangeRequests } from './ClientChangeRequests';

const api = vi.hoisted(() => ({ list: vi.fn(), get: vi.fn(), contactChanges: vi.fn(), decide: vi.fn() }));

vi.mock('@/services/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/services/api')>()),
  clientEmployeeChangeRequestsApi: api,
}));

const request: EmployeeChangeRequest = {
  id: 1, status: 'pending', request_kind: 'update', employee_id: 1,
  employee_name: 'Example Worker', requested_by_id: 2, created_at: '2026-11-25T00:00:00Z',
};
const approved = { ...request, id: 2, status: 'approved' as const };
const deepLinked = { ...request, id: 8, employee_name: 'Another Worker' };
const meta = { profile_requests_enabled: true, current_page: 1, total_pages: 1, total_count: 1 };

beforeEach(() => {
  vi.resetAllMocks();
  api.list.mockResolvedValue({ data: [request], meta });
  api.get.mockImplementation((id: number) => Promise.resolve({
    data: [request, approved, deepLinked].find((item) => item.id === id),
  }));
});
afterEach(cleanup);

function open(path: string) {
  render(<MemoryRouter initialEntries={[path]}><ClientChangeRequests /></MemoryRouter>);
}

it('uses the deep link once and selects from the current search and status results', async () => {
  api.list.mockResolvedValueOnce({ data: [request], meta })
    .mockResolvedValueOnce({ data: [request], meta })
    .mockResolvedValueOnce({ data: [approved], meta });
  open('/change-requests?request_id=8');
  await screen.findByText('Request #8');

  fireEvent.change(screen.getByRole('textbox', { name: 'Search employees' }), { target: { value: '  Example Worker  ' } });
  await screen.findByText('Request #1');
  expect(api.list).toHaveBeenLastCalledWith({ search: 'Example Worker', status: undefined });

  fireEvent.change(screen.getByRole('combobox', { name: 'Request status' }), { target: { value: 'approved' } });
  await screen.findByText('Request #2');
  expect(api.get.mock.calls.map(([id]) => id)).toEqual([8, 1, 2]);
});

it('falls back to a visible request when the incoming request ID returns 404', async () => {
  api.get.mockRejectedValueOnce(new ApiError('Change request not found', 404));
  open('/change-requests?request_id=999');
  await screen.findByText('Request #1');
  expect(screen.getByRole('button', { name: 'View request' })).toBeTruthy();
  expect(screen.queryByText('Change request not found')).toBeNull();
  expect(api.get.mock.calls.map(([id]) => id)).toEqual([999, 1]);
});

it('loads contact activity without fetching request details', async () => {
  api.contactChanges.mockResolvedValue({ data: [], meta: { ...meta, total_count: 0 } });
  open('/change-requests?view=contact&request_id=8');
  await screen.findByText('No contact changes found.');
  expect(api.get).not.toHaveBeenCalled();
});

it.each([
  ['pending', 'Current', 'Requested'],
  ['cancelled', 'Before', 'Requested'],
  ['rejected', 'Before', 'Requested'],
  ['approved', 'Before', 'After'],
] as const)('labels both address columns for a %s request', async (status, original, result) => {
  const addressRequest = {
    ...request,
    status,
    profile_address: true,
    original_values: { address_line1: '100 Example Lane' },
    proposed_changes: { address_line1: '200 Example Lane' },
  };
  api.list.mockResolvedValue({ data: [addressRequest], meta });
  api.get.mockResolvedValue({ data: addressRequest });

  open('/change-requests');
  expect(await screen.findByRole('columnheader', { name: original })).toBeTruthy();
  expect(screen.getByRole('columnheader', { name: result })).toBeTruthy();
});

it.each([
  ['Approve', 'Approve address', 'approve', true, "Note to the employee (they'll see this)"],
  ['Reject', 'Reject request', 'reject', true, "Note to the employee (they'll see this)"],
  ['Approve', 'Approve address', 'approve', false, 'Review note'],
])('labels the optional client note for %s (%s, %s, employee visibility %s)', async (action, confirmation, decision, visible, label) => {
  const pendingAddress = { ...request, profile_address: true, can_review: true, note_visible_to_employee: visible };
  api.list.mockResolvedValue({ data: [pendingAddress], meta });
  api.get.mockResolvedValue({ data: pendingAddress });
  api.decide.mockResolvedValue({ data: { ...pendingAddress, status: decision === 'approve' ? 'approved' : 'rejected' } });

  open('/change-requests');
  fireEvent.click(await screen.findByRole('button', { name: action }));
  const note = screen.getByRole<HTMLInputElement>('textbox', { name: label });
  expect(note.required).toBe(false);
  fireEvent.click(screen.getByRole('button', { name: confirmation }));
  await waitFor(() => expect(api.decide).toHaveBeenCalledWith(pendingAddress.id, decision, undefined));
});

it('explains what change requests are and how to ask for one when there are none', async () => {
  api.list.mockResolvedValue({ data: [], meta: { ...meta, profile_requests_enabled: false, total_count: 0 } });
  open('/change-requests');

  expect(await screen.findByText('No change requests yet.')).toBeTruthy();
  expect(screen.getByText(/Cornerstone reviews the change before payroll uses it/)).toBeTruthy();
  expect(screen.queryByText(/Address changes employees ask for/)).toBeNull();
  expect(screen.getByRole('link', { name: 'Employees' }).getAttribute('href')).toBe('/employees');
  expect(screen.queryByText('No change requests found.')).toBeNull();
});

it('says no requests match when filters hide them', async () => {
  api.list.mockResolvedValue({ data: [], meta: { ...meta, total_count: 0 } });
  open('/change-requests');
  await screen.findByText('No change requests yet.');
  expect(screen.getByText(/Address changes employees ask for in the employee app appear here too/)).toBeTruthy();

  fireEvent.change(screen.getByRole('combobox', { name: 'Request status' }), { target: { value: 'approved' } });
  expect(await screen.findByText('No change requests match these filters.')).toBeTruthy();
});
