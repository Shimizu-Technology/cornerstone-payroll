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
  HTMLElement.prototype.scrollTo = vi.fn(function (this: HTMLElement, options?: ScrollToOptions | number, y?: number) { this.scrollTop = typeof options === 'number' ? y || 0 : options?.top || 0; });
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
  expect(destination).toContain('/companies/2/client-messages?');
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

it('refreshes every loaded page atomically and preserves scroll during a live burst', async () => {
  const meta = (next: string | null) => ({ next_cursor: next });
  mocks.list.mockImplementation(({ cursor }) => Promise.resolve(cursor ? { data: [row('document', 2)], meta: meta(null) } : { data: [row('message')], meta: meta('page2') }));
  render(<MemoryRouter initialEntries={['/app/client-inbox?client=2']}><main><ClientInbox /></main></MemoryRouter>);
  await screen.findByText('message item 1');
  fireEvent.click(screen.getByRole('button', { name: 'Load more' }));
  await screen.findByText('document item 2');
  const main = screen.getByRole('main');
  main.scrollTop = 700;
  fireEvent.scroll(main);
  const before = mocks.list.mock.calls.length;
  mocks.list.mockImplementation(({ cursor }) => Promise.resolve(cursor ? { data: [row('document', 2)], meta: meta(null) } : { data: [row('message', 3), row('message')], meta: meta('fresh-page2') }));
  act(() => { for (let n = 0; n < 5; n++) window.dispatchEvent(new Event('portal-work-changed')); });
  await screen.findByText('message item 3');
  expect(screen.getByText('document item 2')).toBeTruthy();
  expect(screen.getAllByText('message item 1')).toHaveLength(1);
  expect(mocks.list.mock.calls.length - before).toBe(2);
  expect(mocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: 'fresh-page2' }));
  expect(main.scrollTop).toBe(700);
});

it('removes an obsolete pagination cursor after a failed first-page refresh', async () => {
  mocks.list.mockResolvedValueOnce({ data: [row('message')], meta: { next_cursor: 'obsolete' } });
  render(<MemoryRouter initialEntries={['/app/client-inbox?kind=document']}><ClientInbox /></MemoryRouter>);
  await screen.findByText('message item 1');
  mocks.list.mockRejectedValueOnce(new Error('Access changed'));
  fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
  await screen.findByRole('alert');
  expect(screen.queryByRole('button', { name: 'Load more' })).toBeNull();
  expect(screen.queryByText('message item 1')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await screen.findByText('message item 1');
  expect(mocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: undefined }));
});

it('stops automatic scroll restoration after a page failure and retries that cursor only on request', async () => {
  let short = false;
  let failPage!: (error: Error) => void;
  mocks.list.mockImplementation(({ cursor }) => {
    if (cursor === 'restore3') return new Promise((_resolve, reject) => { failPage = reject; });
    if (cursor === 'fresh2') return Promise.resolve({ data: [row('message', 4)], meta: { next_cursor: 'restore3' } });
    if (cursor) return Promise.resolve({ data: [row('message', 2)], meta: { next_cursor: 'old3' } });
    return Promise.resolve({ data: [row('message', short ? 3 : 1)], meta: { next_cursor: short ? 'fresh2' : 'old2' } });
  });
  render(<MemoryRouter initialEntries={['/app/client-inbox?client=2&status=all']}><main><ClientInbox /></main></MemoryRouter>);
  await screen.findByText('message item 1');
  const main = screen.getByRole('main');
  Object.defineProperty(main, 'scrollHeight', { configurable: true, get: () => short ? 500 : 3000 });
  Object.defineProperty(main, 'clientHeight', { configurable: true, value: 500 });
  fireEvent.click(screen.getByRole('button', { name: 'Load more' }));
  await screen.findByText('message item 2');
  main.scrollTop = 1400;
  fireEvent.scroll(main);
  short = true;
  act(() => window.dispatchEvent(new Event('portal-work-changed')));
  await waitFor(() => expect(mocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: 'restore3' })));
  await act(async () => failPage(new Error('Page temporarily unavailable')));
  await screen.findByRole('alert');
  expect(mocks.list).toHaveBeenCalledTimes(5);
  expect(screen.getByText('message item 3')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Load more' }) as HTMLButtonElement).disabled).toBe(false);
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  expect(mocks.list).toHaveBeenCalledTimes(6);
  expect(mocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: 'restore3' }));
});

it('opens pay-period submissions on the period page for that client', async () => {
  mocks.list.mockResolvedValue({ data: [{ ...row('payroll_submission', 7), title: 'Payroll Nov 2–15, 2026' }], meta: { next_cursor: null } });
  render(<MemoryRouter initialEntries={['/app/client-inbox']}><ClientInbox /><Destination /></MemoryRouter>);
  const button = await screen.findByRole('button', { name: /Payroll Nov 2–15, 2026/ });
  expect(button.textContent).toContain('Second client · Pay period files');
  fireEvent.click(button);
  expect(mocks.switchCompany).toHaveBeenCalledWith(2);
  const destination = screen.getByTestId('destination').textContent!;
  expect(destination.split('?')[0]).toBe('/companies/2/payroll-submissions/7');
  expect(new URLSearchParams(destination.split('?')[1]).get('inbox')).toBe('/app/client-inbox');
});
