// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter, useLocation } from 'react-router';
import { ClientInbox } from './ClientInbox';
import { mergeInboxRows, type InboxRow } from '@/services/clientInbox';
const mocks = vi.hoisted(() => ({ list: vi.fn(), counts: vi.fn(), switchCompany: vi.fn() }));
vi.mock('@/services/clientInbox', async original => ({ ...await original<object>(), clientInboxApi: { list: mocks.list, counts: mocks.counts } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1 } }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ companies: [{ id: 2, name: 'Second client', active: true, payroll_environment: 'live' }], switchCompany: mocks.switchCompany }) }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
const row = (kind: InboxRow['kind'], id = 1): InboxRow => ({ id, key: `${kind}:${id}`, kind, company_id: 2, company_name: 'Second client', title: `${kind} item ${id}`, activity_at: '2026-11-12T00:00:00Z', unread: true, waiting: true });
function Destination() {
  const location = useLocation();
  return <output data-testid="destination">{location.pathname + location.search}</output>;
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.list.mockResolvedValue({ data: [row('message')], meta: { next_cursor: null } });
  mocks.counts.mockResolvedValue({ data: { unread_count: 310, unread_messages: 210, unread_documents: 100, waiting_count: 320 } });
  mocks.switchCompany.mockReturnValue(true);
});
afterEach(cleanup);
it('deduplicates refresh/page overlap by kind and id, replacing stale row data', () => {
  expect(mergeInboxRows([row('message'), row('document')], [{ ...row('message'), waiting: false }, row('document', 2)])).toEqual([{ ...row('message'), waiting: false }, row('document'), row('document', 2)]);
});
it('shows server-wide counts and only switches company when opening a row', async () => {
  render(<MemoryRouter initialEntries={['/app/client-inbox?kind=message']}><ClientInbox /><Destination /></MemoryRouter>);
  await screen.findByText('message item 1');
  expect(screen.getByText('310')).toBeTruthy();
  expect(mocks.switchCompany).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'unread' } });
  await waitFor(() => expect(mocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ status: 'unread' })));
  expect(mocks.switchCompany).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: /message item 1/ }));
  expect(mocks.switchCompany).toHaveBeenCalledWith(2);
  const destination = screen.getByTestId('destination').textContent!;
  expect(destination).toContain('/companies/2/client-documents?');
  expect(new URLSearchParams(destination.split('?')[1]).get('thread_id')).toBe('1');
  expect(new URLSearchParams(destination.split('?')[1]).get('inbox')).toContain('/app/client-inbox?');
});
it('refreshes live work without duplicate rows and drops newly inaccessible companies', async () => {
  mocks.list.mockResolvedValueOnce({ data: [row('message')], meta: { next_cursor: 'next' } });
  render(<MemoryRouter><ClientInbox /></MemoryRouter>);
  await screen.findByText('message item 1');
  mocks.list.mockResolvedValueOnce({ data: [row('message'), row('document')], meta: { next_cursor: null } });
  fireEvent.click(screen.getByRole('button', { name: 'Load more' }));
  await screen.findByText('document item 1');
  expect(screen.getAllByText('message item 1')).toHaveLength(1);
  mocks.list.mockResolvedValueOnce({ data: [], meta: { next_cursor: null } });
  await act(async () => { window.dispatchEvent(new Event('portal-work-changed')); });
  await screen.findByText('No portal work matches these filters.');
  expect(screen.queryByText('message item 1')).toBeNull();
});
