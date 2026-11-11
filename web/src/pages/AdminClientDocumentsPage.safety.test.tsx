// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AdminClientDocumentsPage } from './AdminClientDocumentsPage';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({ list: vi.fn(), employees: vi.fn(), upload: vi.fn(), delete: vi.fn() }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/client-portal/PortalMessagesPanel', () => ({ PortalMessagesPanel: () => null }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: () => null }));
vi.mock('@/services/api', () => ({
  adminClientDocumentsApi: { list: mocks.list, upload: mocks.upload, delete: mocks.delete },
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

it('shows successful archival and disables file actions after refresh', async () => {
  const user = userEvent.setup();
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  mocks.delete.mockResolvedValue({ message: 'File archived. It is kept with its messages.' });
  render(<AdminClientDocumentsPage />);
  await screen.findAllByText('Payroll hours');
  mocks.list.mockResolvedValue({ data: [{ ...document, archived_at: '2026-11-11T00:00:00Z' }] });
  await user.click(screen.getAllByRole('button', { name: 'Delete' })[0]);
  expect(await screen.findByText('File archived. It is kept with its messages.')).toBeTruthy();
  expect(screen.getAllByText('File archived · kept as evidence')).toHaveLength(2);
  for (const button of screen.getAllByRole('button', { name: /^(Preview|Download|Delete)$/ })) expect((button as HTMLButtonElement).disabled).toBe(true);
});
