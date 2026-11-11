// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AdminClientDocumentsPage } from './AdminClientDocumentsPage';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({ list: vi.fn(), employees: vi.fn(), upload: vi.fn(), delete: vi.fn(), unarchive: vi.fn() }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/client-portal/PortalMessagesPanel', () => ({ PortalMessagesPanel: () => null }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: () => null }));
vi.mock('@/services/api', () => ({
  adminClientDocumentsApi: { list: mocks.list, upload: mocks.upload, delete: mocks.delete, unarchive: mocks.unarchive },
  employeesApi: { list: mocks.employees }, adminPortalThreadsApi: {},
}));
const document = { id: 1, title: 'Payroll hours', file_name: 'hours.csv', category: 'payroll_source', created_at: '2026-11-11T00:00:00Z', file_size: 100, uploaded_by_id: 1, visible_to_client: true } as ClientDocument;
beforeEach(() => {
  vi.clearAllMocks();
  mocks.list.mockResolvedValue({ data: [document] });
  mocks.employees.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

it('keeps the chosen upload and shows its plain server error', async () => {
  const user = userEvent.setup();
  mocks.upload.mockRejectedValue(new Error('File notice.pdf does not match its file extension. Please export it again.'));
  const { container } = render(<AdminClientDocumentsPage />);
  await screen.findAllByText('Payroll hours');
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, new File(['synthetic'], 'notice.pdf', { type: 'application/pdf' }));
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('does not match'));
  expect(screen.getByText('notice.pdf')).toBeTruthy();
});

it('keeps archived evidence readable and offers staff unarchive', async () => {
  const user = userEvent.setup();
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  mocks.delete.mockResolvedValue({ message: 'File archived. It is kept with its messages.' });
  render(<AdminClientDocumentsPage />);
  await screen.findAllByText('Payroll hours');
  mocks.list.mockResolvedValue({ data: [{ ...document, archived_at: '2026-11-11T00:00:00Z' }] });
  await user.click(screen.getAllByRole('button', { name: 'Delete' })[0]);
  expect(await screen.findByText('File archived. It is kept with its messages.')).toBeTruthy();
  expect(screen.getAllByText('File archived · kept as evidence')).toHaveLength(2);
  for (const button of screen.getAllByRole('button', { name: /^(Preview|Download)$/ })) expect((button as HTMLButtonElement).disabled).toBe(false);
  expect(screen.getAllByRole('button', { name: 'Unarchive' })).toHaveLength(2);
  mocks.unarchive.mockResolvedValue({ message: 'File unarchived.' });
  mocks.list.mockResolvedValue({ data: [document] });
  await user.click(screen.getAllByRole('button', { name: 'Unarchive' })[0]);
  expect(await screen.findByText('File unarchived.')).toBeTruthy();
  expect(mocks.unarchive).toHaveBeenCalledWith(1);
  expect(screen.queryByText('File archived · kept as evidence')).toBeNull();
});

it('uploads 30 images in three sequential requests and shows progress', async () => {
  const user = userEvent.setup();
  let finishFirst!: (value: unknown) => void;
  mocks.upload.mockImplementationOnce(() => new Promise((resolve) => { finishFirst = resolve; }))
    .mockResolvedValue({ data: [], message: 'Shared' });
  const { container } = render(<AdminClientDocumentsPage />);
  await screen.findAllByText('Payroll hours');
  const files = Array.from({ length: 30 }, (_, i) => new File(['image'], `timesheet-${i}.jpg`, { type: 'image/jpeg' }));
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, files);
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(mocks.upload).toHaveBeenCalledTimes(1);
  expect((mocks.upload.mock.calls[0][0] as FormData).getAll('files[]')).toHaveLength(10);
  expect(screen.getByRole('status').textContent).toContain('0 of 30');
  finishFirst({ data: [] });
  expect(await screen.findByText('30 documents shared successfully')).toBeTruthy();
  expect(mocks.upload).toHaveBeenCalledTimes(3);
  for (const [payload] of mocks.upload.mock.calls) expect(payload.getAll('files[]')).toHaveLength(10);
});


it('reports the failed filename and retains only that file after a mixed batch', async () => {
  const user = userEvent.setup();
  mocks.upload.mockImplementation(async (payload: FormData) => {
    const files = payload.getAll('files[]') as File[];
    if (files.some((file) => file.name === 'bad.jpg')) throw Object.assign(new Error('File does not match its extension.'), { status: 422 });
    return { data: [] };
  });
  const { container } = render(<AdminClientDocumentsPage />);
  await screen.findAllByText('Payroll hours');
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement,
    [new File(['good'], 'good.jpg', { type: 'image/jpeg' }), new File(['bad'], 'bad.jpg', { type: 'image/jpeg' })]);
  await user.click(screen.getByRole('button', { name: 'Share Document' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('bad.jpg: File does not match'));
  expect(screen.getByText('Document shared successfully')).toBeTruthy();
  expect(screen.getByText('bad.jpg')).toBeTruthy();
  expect(screen.queryByText('good.jpg')).toBeNull();
});
