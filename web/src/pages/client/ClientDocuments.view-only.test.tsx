// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ClientDocument } from '@/services/api';
import { ClientDocuments } from './ClientDocuments';

const mocks = vi.hoisted(() => ({ list: vi.fn(), employees: vi.fn(), upload: vi.fn(), delete: vi.fn() }));
const auth = vi.hoisted(() => ({ isClientViewer: false }));
vi.mock('@/contexts/AuthContext', () => ({ useOptionalAuth: () => auth }));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <header><h1>{title}</h1></header> }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({ DocumentPreviewModal: () => null }));
vi.mock('@/services/api', () => ({
  getActiveCompanyId: () => 1,
  clientDocumentsApi: { list: mocks.list, upload: mocks.upload, delete: mocks.delete },
  clientEmployeesApi: { list: mocks.employees },
}));

const doc = {
  id: 3, company_id: 1, employee_id: null, employee_name: null, title: 'Tax notice', category: 'tax_notice',
  file_name: 'notice.pdf', file_size: 2048, content_type: 'application/pdf', created_at: '2026-11-01T09:00:00Z',
  updated_at: '2026-11-01T09:00:00Z', uploaded_by_id: 4, visible_to_client: true, shared_by_staff: false,
  preview_status: 'ready', preview_available: true,
} as ClientDocument;

beforeEach(() => {
  vi.clearAllMocks();
  mocks.employees.mockResolvedValue({ data: [] });
  mocks.list.mockResolvedValue({ data: [doc], meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 25 } });
});
afterEach(() => { cleanup(); auth.isClientViewer = false; });

it('lets a client viewer open and download documents but not upload or delete them', async () => {
  auth.isClientViewer = true;
  render(<ClientDocuments />);

  expect((await screen.findAllByText('Tax notice')).length).toBeGreaterThan(0);
  expect(screen.getByText('Your access is view-only. Ask your account manager for changes.')).toBeTruthy();
  expect(screen.getAllByRole('button', { name: /Download/ }).length).toBeGreaterThan(0);
  expect(screen.queryByRole('button', { name: /Upload Document/ })).toBeNull();
  expect(screen.queryByRole('button', { name: /Delete/ })).toBeNull();
});

it('keeps upload and delete for a client manager', async () => {
  render(<ClientDocuments />);

  expect((await screen.findAllByText('Tax notice')).length).toBeGreaterThan(0);
  expect(screen.getByRole('button', { name: /Upload Document/ })).toBeTruthy();
  expect(screen.getAllByRole('button', { name: /Delete/ }).length).toBeGreaterThan(0);
});
