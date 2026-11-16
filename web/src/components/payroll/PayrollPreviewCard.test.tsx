// @vitest-environment jsdom
import { act, fireEvent, render, screen, waitFor, cleanup } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PayrollPreviewCard } from './PayrollPreviewCard';
import { checksApi } from '@/services/api';
import type { PayPeriod } from '@/types';

vi.mock('@/services/api', () => ({ checksApi: { previewPdf: vi.fn() } }));
// The shared menu has its own browser keyboard/popover coverage. Exercise the
// card's format wiring here without depending on jsdom's missing popover API.
vi.mock('@/components/reports/ReportDownloadMenu', () => ({
  ReportDownloadMenu: ({ formats, buttonLabel, disabled }: { formats: { key: string; label: string; loading: boolean; onSelect: () => Promise<void> }[]; buttonLabel: string; disabled: boolean }) => <div>
    <button disabled={disabled}>{buttonLabel}</button>
    {formats.map(format => <button key={format.key} disabled={disabled || format.loading} onClick={() => void format.onSelect()}>{format.label}</button>)}
  </div>,
}));
const period = { id: 11, company_id: 2, status: 'approved', payroll_review: { revision: 3 } } as PayPeriod;

describe('PayrollPreviewCard', () => {
  beforeEach(() => {
    vi.mocked(checksApi.previewPdf).mockReset();
    vi.stubGlobal('URL', { createObjectURL: vi.fn(() => 'blob:preview'), revokeObjectURL: vi.fn() });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  });
  afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it.each(['draft', 'committed'] as const)('hides preview for %s payroll', status => {
    render(<PayrollPreviewCard payPeriod={{ ...period, status }} />);
    expect(screen.queryByText('Download preview')).toBeNull();
  });

  it('hides preview for voided payroll', () => {
    render(<PayrollPreviewCard payPeriod={{ ...period, correction_status: 'voided' }} />);
    expect(screen.queryByText('Download preview')).toBeNull();
  });

  it('shows the previous download revision after recalculation', () => {
    render(<PayrollPreviewCard payPeriod={{ ...period, last_preview_download: { revision: 2, downloaded_at: '' } }} />);
    expect(screen.getByText('The last preview was revision 2; download a new one.')).toBeTruthy();
  });

  it.each(['calculated', 'approved'] as const)('offers the three preview parts on %s payroll', async status => {
    vi.mocked(checksApi.previewPdf).mockResolvedValue({ blob: new Blob(['pdf']), filename: 'Example_PREVIEW_2026-11-19_rev3.pdf' });
    render(<PayrollPreviewCard payPeriod={{ ...period, status }} />);
    expect(screen.getByText('Watermarked PREVIEW, no check numbers. Send it to the client to review before you commit.')).toBeTruthy();
    for (const [label, part] of [['Checks and pay stubs', undefined], ['Checks only', 'checks'], ['Pay stubs only', 'stubs']] as const) {
      fireEvent.click(screen.getByRole('button', { name: label }));
      await waitFor(() => expect(checksApi.previewPdf).toHaveBeenLastCalledWith(11, 2, part));
      await waitFor(() => expect(screen.getByRole('button', { name: 'Download preview' }).hasAttribute('disabled')).toBe(false));
    }
  });

  it('shows the last revision until a fresh preview succeeds and preserves the server filename', async () => {
    vi.mocked(checksApi.previewPdf).mockResolvedValue({ blob: new Blob(['pdf']), filename: 'Example_PREVIEW_2026-11-19_rev3.pdf' });
    render(<PayrollPreviewCard payPeriod={{ ...period, last_preview_download: { revision: 2, downloaded_at: '2026-11-16T00:00:00Z' } }} />);
    expect(screen.getByText('The last preview was revision 2; download a new one.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Checks and pay stubs' }));
    await waitFor(() => expect(screen.queryByText(/The last preview/)).toBeNull());
    expect(HTMLAnchorElement.prototype.click).toHaveBeenCalled();
  });

  it('shows a download error and allows retry without losing stale revision feedback', async () => {
    vi.mocked(checksApi.previewPdf).mockRejectedValue(new Error('No checks are available for this preview'));
    render(<PayrollPreviewCard payPeriod={{ ...period, last_preview_download: { revision: 2, downloaded_at: '' } }} />);
    fireEvent.click(screen.getByRole('button', { name: 'Checks only' }));
    expect(await screen.findByText('No checks are available for this preview')).toBeTruthy();
    expect(screen.getByText('The last preview was revision 2; download a new one.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Download preview' }).hasAttribute('disabled')).toBe(false);
  });

  it('disables duplicate downloads while preparing and refreshes the run after success', async () => {
    let complete!: (value: { blob: Blob; filename: string }) => void;
    vi.mocked(checksApi.previewPdf).mockReturnValue(new Promise(resolve => { complete = resolve; }));
    const refresh = vi.fn();
    render(<PayrollPreviewCard payPeriod={period} compact onDownloaded={refresh} />);
    fireEvent.click(screen.getByRole('button', { name: 'Checks and pay stubs' }));
    expect(screen.getByRole('button', { name: 'Preparing preview…' }).hasAttribute('disabled')).toBe(true);
    await act(async () => complete({ blob: new Blob(['pdf']), filename: 'Example_rev3.pdf' }));
    expect(refresh).toHaveBeenCalledTimes(1);
  });
});
