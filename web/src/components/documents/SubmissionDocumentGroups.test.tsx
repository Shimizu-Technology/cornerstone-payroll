// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { ClientDocument } from '@/services/api';
import { SubmissionDocumentGroups } from './SubmissionDocumentGroups';

const group = { id: 7, label: 'Pay period files · Nov 2 – Nov 15 · revision 2' };
const file = (id: number, file_name: string, extra: Partial<ClientDocument> = {}) => ({
  id, file_name, title: file_name, created_at: '2026-11-15T02:00:00Z', uploaded_by_name: 'Emma', preview_available: false, submission_groups: [ group ], ...extra,
}) as ClientDocument;
afterEach(cleanup);

it('lists every file of a revision once, with who sent it, and keeps preview for spreadsheets', () => {
  const onPreview = vi.fn().mockResolvedValue(undefined);
  render(<SubmissionDocumentGroups documents={[ file(1, 'hours.pdf'), file(2, 'changes.xlsx') ]} onPreview={onPreview} onDownload={vi.fn()} />);
  expect(screen.getAllByText(group.label, { exact: false })).toHaveLength(1);
  expect(screen.getByText(/2 files/)).toBeTruthy();
  expect(screen.getAllByText(/Emma/)).toHaveLength(2);
  fireEvent.click(screen.getByRole('button', { name: 'Preview changes.xlsx' }));
  expect(onPreview).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }));
});

it('shows archived files and the staff actions passed in', () => {
  render(<SubmissionDocumentGroups allowArchived documents={[ file(3, 'hours.pdf', { archived_at: '2026-11-16T00:00:00Z' }) ]} onPreview={vi.fn()} onDownload={vi.fn()}
    extraActions={document => <button type="button">Unarchive {document.file_name}</button>} />);
  expect(screen.getByText('File archived · kept as evidence')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Unarchive hours.pdf' })).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Download hours.pdf' }) as HTMLButtonElement).disabled).toBe(false);
});

it('keeps a group the page has marked open expanded when it remounts after a reload', () => {
  const onToggleGroup = vi.fn();
  const view = () => <SubmissionDocumentGroups openGroups={new Set([ group.id ])} onToggleGroup={onToggleGroup} documents={[ file(1, 'hours.pdf') ]} onPreview={vi.fn()} onDownload={vi.fn()} />;
  const first = render(view());
  first.unmount();
  const { container } = render(view());
  expect(container.querySelector('details')?.open).toBe(true);
});

it('dates a group by when the revision was sent, not when a retained file was first uploaded', () => {
  const retained = { ...group, submitted_at: '2026-11-14T18:00:00Z' };
  render(<SubmissionDocumentGroups documents={[ file(1, 'hours.pdf', { created_at: '2026-11-01T02:00:00Z', submission_groups: [ retained ] }) ]} onPreview={vi.fn()} onDownload={vi.fn()} />);
  expect(screen.getByText(/sent Nov 15, 2026/)).toBeTruthy();
});
