// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { EmployeeChangeRequest } from '@/services/api';
import { ClientChangeRequests } from './ClientChangeRequests';

const mocks = vi.hoisted(() => ({ list: vi.fn(), get: vi.fn() }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/services/api', () => ({ clientEmployeeChangeRequestsApi: { list: mocks.list, get: mocks.get } }));

const request = (id: number): EmployeeChangeRequest => ({
  id, status: 'approved', request_kind: 'update', employee_id: id, employee_name: `Worker ${id}`,
  requested_by_id: 4, requested_by_name: 'Synthetic Client', created_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z',
} as EmployeeChangeRequest);
const meta = (page: number) => ({ current_page: page, total_pages: 2, total_count: 3, per_page: 2 });

beforeEach(() => {
  vi.clearAllMocks();
  mocks.get.mockImplementation((id: number) => Promise.resolve({ data: request(id) }));
  mocks.list.mockImplementation((params?: { page?: number }) => Promise.resolve(
    params?.page === 2 ? { data: [request(1)], meta: meta(2) } : { data: [request(3), request(2)], meta: meta(1) },
  ));
});
afterEach(cleanup);

it('shows the total and loads the next page with the same filters', async () => {
  const user = userEvent.setup();
  render(<MemoryRouter><ClientChangeRequests /></MemoryRouter>);

  expect((await screen.findByText(/Showing/)).textContent).toBe('Showing 2 of 3 change requests');
  await user.click(screen.getByRole('button', { name: 'Load more change requests' }));

  expect((await screen.findAllByText('Worker 1')).length).toBeGreaterThan(0);
  expect(mocks.list).toHaveBeenLastCalledWith({ search: undefined, status: undefined, page: 2 });
  expect(screen.queryByText(/Showing/)).toBeNull();
});
