// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ClientDocument, ClientDocumentListMeta } from '@/services/api';
import { ClientDocuments } from './ClientDocuments';

const mocks = vi.hoisted(() => ({ list: vi.fn(), employees: vi.fn(), upload: vi.fn(), delete: vi.fn() }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/client-portal/PortalMessagesPanel', () => ({ PortalMessagesPanel: () => null }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: () => null }));
vi.mock('@/services/api', () => ({
  clientDocumentsApi: { list: mocks.list, upload: mocks.upload, delete: mocks.delete },
  clientEmployeesApi: { list: mocks.employees },
  clientPortalThreadsApi: {},
}));

const doc = (id: number, employeeId: number | null = 7): ClientDocument => ({
  id, company_id: 1, employee_id: employeeId, employee_name: employeeId ? 'Synthetic Worker' : null,
  title: `Onboarding ${id}`, category: 'employee_onboarding', file_name: `w4-${id}.pdf`, file_size: 2048,
  content_type: 'application/pdf', created_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z',
  uploaded_by_id: 4, visible_to_client: true, shared_by_staff: false, preview_status: 'ready', preview_available: true,
} as ClientDocument);
const meta = (page: number): ClientDocumentListMeta => ({ current_page: page, total_pages: 2, total_count: 3, per_page: 2, employee_linked_count: 3 });

beforeEach(() => {
  vi.clearAllMocks();
  mocks.employees.mockResolvedValue({ data: [] });
  mocks.list.mockImplementation((params?: { page?: number }) => Promise.resolve(
    params?.page === 2 ? { data: [doc(1)], meta: meta(2) } : { data: [doc(3), doc(2)], meta: meta(1) },
  ));
});
afterEach(cleanup);

it('shows server totals and appends the next page when Load more is pressed', async () => {
  const user = userEvent.setup();
  render(<ClientDocuments />);

  expect(await screen.findByText(/Showing/)).toHaveProperty('textContent', 'Showing 2 of 3 documents');
  const stored = screen.getByText('Stored in portal').closest('div')?.parentElement as HTMLElement;
  expect(within(stored).getByText('3')).toBeTruthy();
  const linked = screen.getByText('Employee-linked').closest('div')?.parentElement as HTMLElement;
  expect(within(linked).getByText('3')).toBeTruthy();
  expect(screen.queryAllByText('Onboarding 1')).toHaveLength(0);

  await user.click(screen.getByRole('button', { name: 'Load more documents' }));

  expect((await screen.findAllByText('Onboarding 1')).length).toBeGreaterThan(0);
  expect(mocks.list).toHaveBeenLastCalledWith({ page: 2 });
  expect(screen.queryByRole('button', { name: 'Load more documents' })).toBeNull();
  expect(screen.queryByText(/Showing/)).toBeNull();
});

it('keeps loaded rows and offers a retry when the next page fails', async () => {
  const user = userEvent.setup();
  render(<ClientDocuments />);
  await screen.findByText(/Showing/);
  mocks.list.mockRejectedValueOnce(new Error('Network down'));

  await user.click(screen.getByRole('button', { name: 'Load more documents' }));

  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Network down');
  expect(screen.getAllByText('Onboarding 3').length).toBeGreaterThan(0);
  await user.click(screen.getByRole('button', { name: 'Try again' }));
  expect((await screen.findAllByText('Onboarding 1')).length).toBeGreaterThan(0);
});

it('hides the footer when every document fits on one page', async () => {
  mocks.list.mockResolvedValue({ data: [doc(1, null)], meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 200, employee_linked_count: 0 } });
  render(<ClientDocuments />);

  expect((await screen.findAllByText('Onboarding 1')).length).toBeGreaterThan(0);
  expect(screen.queryByText(/Showing/)).toBeNull();
});

it('shows the server upload rejection and preserves selected files for correction', async () => {
  const user = userEvent.setup();
  mocks.upload.mockRejectedValue(new Error('File notice.pdf does not match its file extension. Please export it again in the correct format.'));
  const { container } = render(<ClientDocuments />);
  await screen.findAllByText('Onboarding 3');
  const file = new File(['synthetic spoof'], 'notice.pdf', { type: 'application/pdf' });
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, file);
  await user.click(screen.getByRole('button', { name: 'Upload Document' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('does not match its file extension'));
  expect(screen.getAllByText('notice.pdf').length).toBeGreaterThan(0);
});

it('shows archive feedback and disables actions for retained files after refresh', async () => {
  const user = userEvent.setup();
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  mocks.delete.mockResolvedValue({ message: 'File archived. It is kept with the messages or evidence that reference it.', data: { ...doc(3), archived_at: '2026-11-11T00:00:00Z' } });
  render(<ClientDocuments />);
  await screen.findAllByText('Onboarding 3');
  mocks.list.mockResolvedValue({ data: [{ ...doc(3), archived_at: '2026-11-11T00:00:00Z' }], meta: { ...meta(1), total_pages: 1, total_count: 1 } });
  await user.click(screen.getAllByRole('button', { name: 'Delete' })[0]);
  await screen.findByText('File archived. It is kept with the messages or evidence that reference it.');
  expect(screen.getAllByText('File archived · kept as evidence')).toHaveLength(2);
  for (const button of screen.getAllByRole('button', { name: /^(Preview|Download|Delete)$/ })) {
    expect((button as HTMLButtonElement).disabled).toBe(true);
  }
  vi.restoreAllMocks();
});

it('uploads 30 selected images in bounded batches', async () => {
  const user = userEvent.setup();
  mocks.upload.mockResolvedValue({ data: [] });
  const { container } = render(<ClientDocuments />);
  await screen.findAllByText('Onboarding 3');
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement,
    Array.from({ length: 30 }, (_, i) => new File(['image'], `timesheet-${i}.jpg`, { type: 'image/jpeg' })));
  await user.click(screen.getByRole('button', { name: 'Upload Document' }));
  expect(await screen.findByText('30 documents uploaded successfully')).toBeTruthy();
  expect(mocks.upload).toHaveBeenCalledTimes(3);
  for (const [payload] of mocks.upload.mock.calls) expect(payload.getAll('files[]')).toHaveLength(10);
});
