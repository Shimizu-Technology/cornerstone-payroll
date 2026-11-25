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
  ['Approve', 'Approve address', 'approve'],
  ['Reject', 'Reject request', 'reject'],
])('explains who sees the optional note when the client clicks %s', async (action, confirmation, decision) => {
  const pendingAddress = { ...request, profile_address: true, can_review: true };
  api.list.mockResolvedValue({ data: [pendingAddress], meta });
  api.get.mockResolvedValue({ data: pendingAddress });
  api.decide.mockResolvedValue({ data: { ...pendingAddress, status: decision === 'approve' ? 'approved' : 'rejected' } });

  open('/change-requests');
  fireEvent.click(await screen.findByRole('button', { name: action }));
  const note = screen.getByRole<HTMLInputElement>('textbox', { name: "Note to the employee (they'll see this)" });
  expect(note.required).toBe(false);
  fireEvent.click(screen.getByRole('button', { name: confirmation }));
  await waitFor(() => expect(api.decide).toHaveBeenCalledWith(pendingAddress.id, decision, undefined));
});
