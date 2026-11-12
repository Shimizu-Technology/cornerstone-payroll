// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { LabeledTextarea } from './LabeledTextarea';
import { PeriodConversation } from './PeriodConversation';
import { FileRow } from './PeriodParts';
import { loadAllEmployees, type PayrollSubmissionsApi } from '@/services/payrollSubmissions';
import type { ClientDocument } from '@/services/api';

vi.mock('@/components/client-portal/useDisplayedMessages', () => ({ useDisplayedMessages: () => ({ current: null }) }));
vi.mock('@/components/documents/DocumentPreviewModal', () => ({
  DocumentPreviewModal: ({ open, onDownload }: { open: boolean; onDownload: () => void }) =>
    open ? <div role="dialog" aria-label="Preview"><button type="button" onClick={onDownload}>Download from preview</button></div> : null,
}));
afterEach(cleanup);

it('keeps the label pointed at the textarea when a caller supplies an id', () => {
  render(<LabeledTextarea label="Notes" id="notes" value="" onChange={() => undefined} />);
  expect(screen.getByLabelText('Notes').id).toBe('notes');
});

it('loads every employee page for the picker', async () => {
  const fetchPage = vi.fn(async (page: number) => ({
    data: page === 1 ? [{ id: 1, first_name: 'Ana', last_name: 'One' }] : [{ id: 201, first_name: 'Zed', last_name: 'Later' }],
    meta: { current_page: page, total_pages: 2, total_count: 2, per_page: 200 },
  }));
  expect(await loadAllEmployees(fetchPage)).toEqual([{ id: 1, name: 'Ana One' }, { id: 201, name: 'Zed Later' }]);
  expect(fetchPage).toHaveBeenCalledTimes(2);
});

it('keeps text typed while a period message is sending', async () => {
  let resolve: () => void = () => undefined;
  const message = vi.fn(() => new Promise<{ data: never; thread_id: number }>(done => { resolve = () => done({ data: undefined as never, thread_id: 3 }); }));
  const api = { message, threads: { get: vi.fn(), markRead: vi.fn() } } as unknown as PayrollSubmissionsApi;
  render(<PeriodConversation api={api} periodRef="9" threadId={null} onThreadCreated={vi.fn()} />);
  const box = screen.getByLabelText('Message') as HTMLTextAreaElement;
  fireEvent.change(box, { target: { value: 'First question' } });
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
  fireEvent.change(box, { target: { value: 'Second question in progress' } });
  resolve();
  await waitFor(() => expect(message).toHaveBeenCalled());
  await waitFor(() => expect(screen.getByRole('button', { name: 'Send message' })).toBeTruthy());
  expect(box.value).toBe('Second question in progress');
});

it('closes the preview and shows a failed download beside the file', async () => {
  const document = { id: 4, title: 'draft.pdf', file_name: 'draft.pdf', content_type: 'application/pdf', preview_available: true, scan_status: 'clean' } as ClientDocument;
  const api = { documents: { preview: vi.fn().mockResolvedValue({ blob: new Blob(['%PDF']) }), download: vi.fn().mockRejectedValue(new Error('Download blocked')) } } as unknown as PayrollSubmissionsApi;
  globalThis.URL.createObjectURL = vi.fn(() => 'blob:x');
  render(<ul><FileRow label="Draft paychecks" document={document} api={api} /></ul>);
  fireEvent.click(screen.getByRole('button', { name: 'Preview draft.pdf' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Download from preview' }));
  expect((await screen.findByRole('alert')).textContent).toBe('Download blocked');
  expect(screen.queryByRole('dialog')).toBeNull();
});
