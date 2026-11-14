// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { PortalImportAction } from './PortalImportAction';
import type { PeriodDetail } from '@/services/payrollSubmissions';
import { ApiError } from '@/services/api';
const mocks = vi.hoisted(() => ({ preview: vi.fn(), resolve: vi.fn() }));
vi.mock('@/services/api', async original => ({ ...await original<typeof import('@/services/api')>(), payPeriodsApi: { previewPortalSubmission: mocks.preview, resolvePortalSource: mocks.resolve } }));
vi.mock('@/components/import/ImportModal', () => ({ ImportModal: ({ initialPreview }: { initialPreview: { portal_source: { revision: number } } }) => <div role="dialog">Review portal revision {initialPreview.portal_source.revision}</div> }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const period = { pay_period_id: 9, submissions: [{ id: 20, revision: 2, current: true }, { id: 10, revision: 1, current: false }] } as PeriodDetail;

it('opens the current retained revision straight in the existing import modal', async () => {
  mocks.preview.mockResolvedValue({ import_id: 30, portal_source: { selection_id: 1, revision: 2 } });
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Review these submitted files' }));
  expect(await screen.findByRole('dialog')).toBeTruthy();
  expect(mocks.preview).toHaveBeenCalledWith(9, 20, expect.objectContaining({ tips_paid_out_from_tips: false }));
  expect(screen.queryByLabelText(/upload/i)).toBeNull();
});

it('requires an explicit reason to select a superseded revision', async () => {
  mocks.preview.mockResolvedValue({ import_id: 30, portal_source: { selection_id: 1, revision: 1 } });
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Client’s revision'), { target: { value: '10' } });
  expect((screen.getByRole('button', { name: 'Review these submitted files' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('Why use an older revision instead of the latest?'), { target: { value: 'Client confirmed revision 2 has wrong dates' } });
  fireEvent.click(screen.getByRole('button', { name: 'Review these submitted files' }));
  await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(9, 10, expect.objectContaining({ superseded_reason: 'Client confirmed revision 2 has wrong dates' })));
});

it('preserves the existing replacement confirmation/reason contract without file transfer', async () => {
  mocks.preview.mockRejectedValueOnce(new ApiError('Confirm replacement', 422, { replacement_required: true, current_package: { package_id: 'retained-package', package_revision: 3 } } as never))
    .mockResolvedValueOnce({ import_id: 31, portal_source: { selection_id: 2, revision: 2 } });
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Review these submitted files' }));
  expect(await screen.findByRole('alert')).toBeTruthy();
  expect(screen.getByText(/already in import review \(import version 3\)/)).toBeTruthy();
  fireEvent.click(screen.getByLabelText('Use corrected files'));
  fireEvent.change(screen.getByLabelText('What changed?'), { target: { value: 'Corrected hours' } });
  fireEvent.click(screen.getByRole('button', { name: 'Use corrected files' }));
  expect(await screen.findByRole('dialog')).toBeTruthy();
  expect(mocks.preview).toHaveBeenLastCalledWith(9, 20, expect.objectContaining({ supersedes_package_id: 'retained-package', supersession_reason: 'Corrected hours' }));
});

it('records a reason against the current revision when staff disposition a wrong-period source', async () => {
  mocks.resolve.mockResolvedValue({ resolved_submission_id: 20 });
  const done = vi.fn();
  render(<PortalImportAction period={period} companyId={7} onApplied={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Don’t use this submission — record why' }));
  fireEvent.change(screen.getByLabelText('Why isn’t the latest revision being used?'), { target: { value: 'Wrong period; client will resend' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save: don’t use the latest revision' }));
  await waitFor(() => expect(done).toHaveBeenCalled());
  expect(mocks.resolve).toHaveBeenCalledWith(9, 20, 'Wrong period; client will resend');
});


it('keeps superseded selection and current disposition reasons independent in both directions', async () => {
  mocks.resolve.mockResolvedValue({ resolved_submission_id: 20 });
  mocks.preview.mockResolvedValue({ import_id: 30, portal_source: { selection_id: 1, revision: 1 } });
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Client’s revision'), { target: { value: '10' } });
  fireEvent.change(screen.getByLabelText('Why use an older revision instead of the latest?'), { target: { value: 'Use old hours confirmed by client' } });
  fireEvent.click(screen.getByRole('button', { name: 'Don’t use this submission — record why' }));
  const save = screen.getByRole('button', { name: 'Save: don’t use the latest revision' }) as HTMLButtonElement;
  expect(save.disabled).toBe(true);
  expect((screen.getByLabelText('Why isn’t the latest revision being used?') as HTMLTextAreaElement).value).toBe('');
  fireEvent.change(screen.getByLabelText('Why isn’t the latest revision being used?'), { target: { value: 'New revision has wrong dates' } });
  fireEvent.click(save);
  await waitFor(() => expect(mocks.resolve).toHaveBeenCalledWith(9, 20, 'New revision has wrong dates'));
  fireEvent.click(screen.getByRole('button', { name: 'Review these submitted files' }));
  await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(9, 10, expect.objectContaining({ superseded_reason: 'Use old hours confirmed by client' })));
});

it('does not use a disposition reason to enable a superseded source', () => {
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Don’t use this submission — record why' }));
  fireEvent.change(screen.getByLabelText('Why isn’t the latest revision being used?'), { target: { value: 'Current files have wrong dates' } });
  fireEvent.change(screen.getByLabelText('Client’s revision'), { target: { value: '10' } });
  expect((screen.getByRole('button', { name: 'Review these submitted files' }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByLabelText('Why use an older revision instead of the latest?') as HTMLTextAreaElement).value).toBe('');
});

it('names the client submission and the import version separately, with plain-language choices', () => {
  render(<PortalImportAction period={period} companyId={7} onApplied={vi.fn()} />);
  expect(screen.getByText(/The import version is separate/)).toBeTruthy();
  const options = Array.from((screen.getByLabelText('Client’s revision') as HTMLSelectElement).options).map(option => option.text);
  expect(options).toEqual(['Revision 2 (latest)', 'Revision 1 (older, replaced by a newer one)']);
  expect(screen.getByRole('button', { name: 'Review these submitted files' })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Don’t use this submission — record why' })).toBeTruthy();
  expect(screen.queryByText(/disposition|retained import package|Source revision/i)).toBeNull();
});

it('shows a link and passes the downloaded workbook as staff evidence for the selected revision', async () => {
  const linked = { ...period, submissions: [{ ...period.submissions[0], documents: [], changes_link_url: 'https://example.test/workbook', workbook_choice: 'link' }] } as PeriodDetail;
  mocks.preview.mockResolvedValue({ import_id: 30, portal_source: { selection_id: 1, revision: 2 } });
  render(<PortalImportAction period={linked} companyId={7} onApplied={vi.fn()} />);
  expect(screen.getByRole('link', { name: 'Client’s tips & loans workbook link' }).getAttribute('href')).toBe('https://example.test/workbook');
  expect(screen.getByText('Open it, download the workbook, and attach it here.')).toBeTruthy();
  const file = new File(['synthetic'], 'downloaded.xlsx');
  fireEvent.change(screen.getByLabelText('Downloaded workbook (Excel)'), { target: { files: [file] } });
  fireEvent.click(screen.getByRole('button', { name: 'Review these submitted files' }));
  await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(9, 20, expect.objectContaining({ staff_workbook: file })));
});


it('clears the downloaded workbook picker when staff select another client revision', async () => {
  const linked = { ...period, submissions: period.submissions.map(row => ({ ...row, documents: [], changes_link_url: 'https://example.test/workbook', workbook_choice: 'link' })) } as PeriodDetail;
  render(<PortalImportAction period={linked} companyId={7} onApplied={vi.fn()} />);
  const picker = screen.getByLabelText('Downloaded workbook (Excel)') as HTMLInputElement;
  await userEvent.upload(picker, new File(['synthetic'], 'downloaded.xlsx'));
  expect(picker.files?.length).toBe(1);
  fireEvent.change(screen.getByLabelText('Client’s revision'), { target: { value: '10' } });
  expect((screen.getByLabelText('Downloaded workbook (Excel)') as HTMLInputElement).files?.length).toBe(0);
});
