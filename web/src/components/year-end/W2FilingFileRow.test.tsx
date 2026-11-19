// @vitest-environment jsdom
import { beforeEach, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { W2FilingFileRow } from './W2FilingFileRow';
import { reportsApi } from '@/services/api';
vi.mock('@/services/api', () => ({ reportsApi: { wageFilingFile: vi.fn() } }));
beforeEach(() => { vi.clearAllMocks(); URL.createObjectURL = vi.fn(() => 'blob:test'); URL.revokeObjectURL = vi.fn(); vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {}); });
it('requires draft confirmation and scopes the download to the checklist client', async () => {
  vi.mocked(reportsApi.wageFilingFile).mockResolvedValue({ blob: new Blob(['data']) });
  render(<W2FilingFileRow companyId={42} year={2026} ready={false} />);
  const button = screen.getByRole('button', { name: 'Download draft EFW2' });
  expect((button as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(button);
  await waitFor(() => expect(reportsApi.wageFilingFile).toHaveBeenCalledWith(2026, 42, 'draft', false));
});
it('requests final PDF only from a ready row and displays server rejection', async () => {
  vi.mocked(reportsApi.wageFilingFile).mockRejectedValue(new Error('Inputs changed; mark ready again'));
  render(<W2FilingFileRow companyId={42} year={2026} ready />);
  fireEvent.click(screen.getAllByRole('button', { name: 'W-3SS records PDF' }).at(-1)!);
  await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Inputs changed'));
  expect(reportsApi.wageFilingFile).toHaveBeenCalledWith(2026, 42, 'final', true);
});
