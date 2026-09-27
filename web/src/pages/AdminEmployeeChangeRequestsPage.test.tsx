// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { EmployeeChangeRequest } from '@/services/api';
import { AdminEmployeeChangeRequestsPage } from './AdminEmployeeChangeRequestsPage';

const apiMocks = vi.hoisted(() => ({ list: vi.fn(), get: vi.fn(), approve: vi.fn(), reject: vi.fn() }));

vi.mock('@/services/api', () => ({
  adminEmployeeChangeRequestsApi: apiMocks,
}));

const request = (id: number, employeeName: string, reviewNotes: string, status: EmployeeChangeRequest['status'] = 'pending'): EmployeeChangeRequest => ({
  id,
  status,
  request_kind: 'update',
  employee_id: id,
  employee_name: employeeName,
  requested_by_id: 9,
  requested_by_name: 'Client Manager',
  review_notes: reviewNotes,
  created_at: '2026-09-27T10:00:00Z',
});

afterEach(cleanup);

it('keeps the newest selected request when detail responses finish out of order', async () => {
  vi.clearAllMocks();
  const alice = request(1, 'Alice Reyes', 'Alice notes');
  const bob = request(2, 'Bob Santos', 'Bob notes');
  let resolveBob!: (value: { data: EmployeeChangeRequest }) => void;
  let resolveAliceAgain!: (value: { data: EmployeeChangeRequest }) => void;
  apiMocks.list.mockResolvedValue({ data: [alice, bob] });
  apiMocks.get.mockResolvedValueOnce({ data: alice })
    .mockImplementationOnce(() => new Promise((resolve) => { resolveBob = resolve; }))
    .mockImplementationOnce(() => new Promise((resolve) => { resolveAliceAgain = resolve; }));

  render(<AdminEmployeeChangeRequestsPage />);
  await screen.findByText('Request #1');
  fireEvent.click(screen.getByRole('button', { name: /Bob Santos/ }));
  fireEvent.click(screen.getByRole('button', { name: /Alice Reyes/ }));
  await act(async () => { resolveAliceAgain({ data: alice }); });
  expect(screen.getByText('Request #1')).toBeTruthy();
  expect((screen.getByRole('textbox') as HTMLTextAreaElement).value).toBe('Alice notes');
  await act(async () => { resolveBob({ data: bob }); });
  expect(screen.getByText('Request #1')).toBeTruthy();
  expect((screen.getByRole('textbox') as HTMLTextAreaElement).value).toBe('Alice notes');
});

it('ignores the previous filter response after the status changes', async () => {
  vi.clearAllMocks();
  const approved = request(3, 'Cara Chen', 'Approved notes', 'approved');
  let resolvePending!: (value: { data: EmployeeChangeRequest[] }) => void;
  apiMocks.list.mockImplementationOnce(() => new Promise((resolve) => { resolvePending = resolve; }))
    .mockResolvedValueOnce({ data: [approved] });
  apiMocks.get.mockResolvedValue({ data: approved });

  render(<AdminEmployeeChangeRequestsPage />);
  await waitFor(() => expect(apiMocks.list).toHaveBeenCalledWith({ status: 'pending' }));
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'approved' } });
  await waitFor(() => expect(apiMocks.list).toHaveBeenCalledTimes(2));
  expect(apiMocks.list.mock.calls.map(([params]) => params?.status)).toEqual(['pending', 'approved']);
  await screen.findByText('Request #3');
  await act(async () => { resolvePending({ data: [request(1, 'Alice Reyes', 'Pending notes')] }); });

  expect(screen.getByRole('button', { name: /Cara Chen/ })).toBeTruthy();
  expect(screen.queryByRole('button', { name: /Alice Reyes/ })).toBeNull();
});

it('refreshes the current filter when approval finishes after a filter change', async () => {
  vi.clearAllMocks();
  const pending = request(1, 'Alice Reyes', 'Pending notes');
  const approved = request(3, 'Cara Chen', 'Approved notes', 'approved');
  let resolveApproval!: () => void;
  apiMocks.list.mockImplementation(({ status }: { status: string }) => Promise.resolve({ data: status === 'pending' ? [pending] : [approved] }));
  apiMocks.get.mockImplementation((id: number) => Promise.resolve({ data: id === pending.id ? pending : approved }));
  apiMocks.approve.mockImplementationOnce(() => new Promise<void>((resolve) => { resolveApproval = resolve; }));

  render(<AdminEmployeeChangeRequestsPage />);
  await screen.findByText('Request #1');
  fireEvent.click(screen.getByRole('button', { name: 'Approve' }));
  await waitFor(() => expect(apiMocks.approve).toHaveBeenCalledOnce());
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'approved' } });
  await screen.findByText('Request #3');

  await act(async () => { resolveApproval(); });
  await waitFor(() => expect(apiMocks.list).toHaveBeenCalledTimes(3));
  expect(apiMocks.list.mock.calls.map(([params]) => params?.status)).toEqual(['pending', 'approved', 'approved']);
  expect(screen.getByText('Request #3')).toBeTruthy();
  expect(screen.queryByRole('button', { name: /Alice Reyes/ })).toBeNull();
});
