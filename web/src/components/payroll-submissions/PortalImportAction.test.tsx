// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
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
  render(<PortalImportAction period={period} onApplied={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Open in import review' }));
  expect(await screen.findByRole('dialog')).toBeTruthy();
  expect(mocks.preview).toHaveBeenCalledWith(9, 20, expect.objectContaining({ tips_paid_out_from_tips: false }));
  expect(screen.queryByLabelText(/upload/i)).toBeNull();
});

it('requires an explicit reason to select a superseded revision', async () => {
  mocks.preview.mockResolvedValue({ import_id: 30, portal_source: { selection_id: 1, revision: 1 } });
  render(<PortalImportAction period={period} onApplied={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Source revision'), { target: { value: '10' } });
  expect((screen.getByRole('button', { name: 'Open in import review' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('Why use this superseded revision?'), { target: { value: 'Client confirmed revision 2 has wrong dates' } });
  fireEvent.click(screen.getByRole('button', { name: 'Open in import review' }));
  await waitFor(() => expect(mocks.preview).toHaveBeenCalledWith(9, 10, expect.objectContaining({ superseded_reason: 'Client confirmed revision 2 has wrong dates' })));
});

it('preserves the existing replacement confirmation/reason contract without file transfer', async () => {
  mocks.preview.mockRejectedValueOnce(new ApiError('Confirm replacement', 422, { replacement_required: true, current_package: { package_id: 'retained-package' } } as never))
    .mockResolvedValueOnce({ import_id: 31, portal_source: { selection_id: 2, revision: 2 } });
  render(<PortalImportAction period={period} onApplied={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Open in import review' }));
  expect(await screen.findByRole('alert')).toBeTruthy();
  fireEvent.click(screen.getByLabelText('Replace the current retained import package'));
  fireEvent.change(screen.getByLabelText('What changed?'), { target: { value: 'Corrected hours' } });
  fireEvent.click(screen.getByRole('button', { name: 'Open in import review' }));
  expect(await screen.findByRole('dialog')).toBeTruthy();
  expect(mocks.preview).toHaveBeenLastCalledWith(9, 20, expect.objectContaining({ supersedes_package_id: 'retained-package', supersession_reason: 'Corrected hours' }));
});

it('records a reason against the current revision when staff disposition a wrong-period source', async () => {
  mocks.resolve.mockResolvedValue({ resolved_submission_id: 20 });
  const done = vi.fn();
  render(<PortalImportAction period={period} onApplied={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Record source disposition' }));
  fireEvent.change(screen.getByLabelText('Why will the current revision not be imported?'), { target: { value: 'Wrong period; client will resend' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save disposition of current revision' }));
  await waitFor(() => expect(done).toHaveBeenCalled());
  expect(mocks.resolve).toHaveBeenCalledWith(9, 20, 'Wrong period; client will resend');
});
