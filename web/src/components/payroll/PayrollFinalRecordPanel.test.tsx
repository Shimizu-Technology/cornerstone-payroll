// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { startTransition, Suspense, useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayrollFinalRecord } from '@/services/api';
import { PayrollFinalRecordPanel } from './PayrollFinalRecordPanel';
import { payrollFinalRecordFixture as record, voidedFinalRecordFixture } from './PayrollFinalRecordPanel.fixtures';
import type { ReportDownloadFormat } from '@/components/reports/ReportDownloadMenu';

const apiMocks = vi.hoisted(() => ({
  payrollFinalRecord: vi.fn(),
  payrollFinalRecordXlsx: vi.fn(),
  payrollFinalRecordPdf: vi.fn(),
}));

vi.mock('@/services/api', () => ({ reportsApi: apiMocks }));
// Exercise the panel's export callbacks without emulating native popover layout.
vi.mock('@/components/reports/ReportDownloadMenu', () => ({
  ReportDownloadMenu: ({ disabled, formats }: { disabled: boolean; formats: ReportDownloadFormat[] }) => <>
    {formats.map(format => <button key={format.key} disabled={disabled || format.loading}
      onClick={() => void format.onSelect()}>{format.label}</button>)}
  </>,
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((success, failure) => { resolve = success; reject = failure; });
  return { promise, resolve, reject };
}

describe('PayrollFinalRecordPanel', () => {
  afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.payrollFinalRecord.mockResolvedValue({ final_record: record });
  });

  it('summarizes payroll truth and opens the supporting record', async () => {
    render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);

    expect(await screen.findByText('In Progress')).toBeTruthy();
    expect(screen.getByText('Balanced')).toBeTruthy();
    expect(screen.getByText('0 of 1 reconciled')).toBeTruthy();
    expect(screen.getByText('$316.50 outstanding')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    expect(screen.getByText(/scheduled pay date 2026-08-20/)).toBeTruthy();
    expect(screen.queryByText(/· paid 2026-08-20/)).toBeNull();
    expect(screen.getByRole('heading', { name: 'Balanced payroll journal' })).toBeTruthy();
    expect(screen.getByText('Reconcile 1 employee check')).toBeTruthy();
    expect(screen.getByText('Mo Shimizu')).toBeTruthy();
    expect(screen.getByText(/Approved review revision 2/)).toBeTruthy();
  });

  it('surfaces load failures as an accessible alert', async () => {
    apiMocks.payrollFinalRecord.mockRejectedValue(new Error('Record unavailable'));
    render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);

    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Record unavailable'));
    expect(screen.getByRole('button', { name: 'View record' }).hasAttribute('disabled')).toBe(true);
  });

  it('does not label direct-deposit stubs as missing checks', async () => {
    apiMocks.payrollFinalRecord.mockResolvedValue({ final_record: {
      ...record,
      employee_payments: {
        ...record.employee_payments,
        required_count: 0,
        direct_deposit_count: 1,
        outstanding_count: 0,
        rows: [{
          ...record.employee_payments.rows[0],
          payment_delivery_method: 'direct_deposit',
          check_number: null,
          issuance_status: 'transfer_not_confirmed',
          reconciliation_status: 'not_tracked',
        }],
      },
    } });
    render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);

    expect(await screen.findByText('0 checks open · 1 direct deposit')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    expect(screen.getByText('Direct deposit · earnings stub ready')).toBeTruthy();
    expect(screen.getByText('Bank transfer not tracked here')).toBeTruthy();
  });

  it('replaces a same-run official record with current voided totals and hides stale details while reloading', async () => {
    const pending = deferred<{ final_record: PayrollFinalRecord }>();
    const { rerender } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    await screen.findByText('$750.00 net');
    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    expect(within(screen.getByRole('dialog')).getByText('Mo Shimizu')).toBeTruthy();
    apiMocks.payrollFinalRecord.mockReturnValueOnce(pending.promise);
    rerender(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} refreshToken={1} />);
    expect(screen.queryByText('$750.00 net')).toBeNull();
    expect(screen.queryByText('Mo Shimizu')).toBeNull();
    expect(screen.queryByText('Reconcile 1 employee check')).toBeNull();
    expect((screen.getByRole('button', { name: 'Loading', hidden: true }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'PDF record (.pdf)', hidden: true }) as HTMLButtonElement).disabled).toBe(true);
    expect(within(screen.getByRole('dialog')).getByRole('status').textContent).toContain('current final payroll record');
    await act(async () => pending.resolve({ final_record: voidedFinalRecordFixture }));
    expect(await screen.findByText('Voided')).toBeTruthy();
    expect(screen.getByText('$0.00 net')).toBeTruthy();
    expect(screen.getByText('0 checks open · 0 direct deposit')).toBeTruthy();
    expect(screen.getByText('$0.00 outstanding')).toBeTruthy();
    expect(within(screen.getByRole('dialog')).getByText('This payroll has been voided')).toBeTruthy();
    expect(screen.queryByText('Reconcile 1 employee check')).toBeNull();
  });

  it('keeps a failed refresh unavailable and retries only the current read from the open record', async () => {
    const { rerender } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    await screen.findByText('$750.00 net');
    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    apiMocks.payrollFinalRecord.mockRejectedValueOnce(new Error('Current record could not load'));
    rerender(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} refreshToken={1} />);
    const dialog = screen.getByRole('dialog');
    expect((await within(dialog).findByRole('alert')).textContent).toContain('Current record could not load');
    expect(screen.queryByText('$750.00 net')).toBeNull();
    expect((screen.getByRole('button', { name: 'PDF record (.pdf)', hidden: true }) as HTMLButtonElement).disabled).toBe(true);
    apiMocks.payrollFinalRecord.mockResolvedValueOnce({ final_record: voidedFinalRecordFixture });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Reload final payroll record' }));
    expect(await screen.findByText('Voided')).toBeTruthy();
    expect(apiMocks.payrollFinalRecord.mock.calls.map(call => call[0])).toEqual([8, 8, 8]);
    expect(apiMocks.payrollFinalRecordPdf).not.toHaveBeenCalled();
    expect(apiMocks.payrollFinalRecordXlsx).not.toHaveBeenCalled();
  });

  it('ignores an old official read that completes after the newer voided revision', async () => {
    const old = deferred<{ final_record: PayrollFinalRecord }>();
    apiMocks.payrollFinalRecord.mockReturnValueOnce(old.promise);
    const { rerender } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    apiMocks.payrollFinalRecord.mockResolvedValueOnce({ final_record: voidedFinalRecordFixture });
    rerender(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} refreshToken={1} />);
    await screen.findByText('Voided');
    await act(async () => old.resolve({ final_record: record }));
    expect(screen.getByText('Voided')).toBeTruthy();
    expect(screen.queryByText('$750.00 net')).toBeNull();
  });

  it('keeps the committed read valid while a newer render suspends without committing', async () => {
    const current = deferred<{ final_record: PayrollFinalRecord }>();
    const suspended = deferred<void>();
    const attempted = vi.fn();
    apiMocks.payrollFinalRecord.mockReturnValueOnce(current.promise);
    function PendingSibling({ pending }: { pending: boolean }) {
      if (pending) {
        attempted();
        throw suspended.promise;
      }
      return null;
    }
    function Harness() {
      const [revision, setRevision] = useState(0);
      return <>
        <button onClick={() => startTransition(() => setRevision(1))}>Start pending revision</button>
        <Suspense fallback={<p>Replacement pending</p>}>
          <PayrollFinalRecordPanel companyId={1} payPeriodId={8} refreshToken={revision} />
          <PendingSibling pending={revision === 1} />
        </Suspense>
      </>;
    }
    render(<Harness />);
    fireEvent.click(screen.getByRole('button', { name: 'Start pending revision' }));
    await waitFor(() => expect(attempted).toHaveBeenCalled());
    expect(screen.queryByText('Replacement pending')).toBeNull();
    await act(async () => current.resolve({ final_record: record }));
    expect(await screen.findByText('$750.00 net')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'View record' }) as HTMLButtonElement).disabled).toBe(false);
    expect(apiMocks.payrollFinalRecord).toHaveBeenCalledOnce();
  });

  it.each(['company', 'pay run'] as const)('clears the previous view immediately when the %s changes', async changed => {
    const next = deferred<{ final_record: PayrollFinalRecord }>();
    const companyId = changed === 'company' ? 2 : 1;
    const payPeriodId = changed === 'pay run' ? 9 : 8;
    const { rerender } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    await screen.findByText('$750.00 net');
    fireEvent.click(screen.getByRole('button', { name: 'View record' }));
    apiMocks.payrollFinalRecord.mockReturnValueOnce(next.promise);
    rerender(<PayrollFinalRecordPanel companyId={companyId} payPeriodId={payPeriodId} />);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.queryByText('$750.00 net')).toBeNull();
    expect((screen.getByRole('button', { name: 'PDF record (.pdf)' }) as HTMLButtonElement).disabled).toBe(true);
    await act(async () => next.resolve({ final_record: { ...voidedFinalRecordFixture,
      company: { id: companyId, name: 'Current company' }, pay_period: { ...record.pay_period, id: payPeriodId } } }));
    expect(await screen.findByText('Voided')).toBeTruthy();
  });

  it('refuses a response for another company instead of exposing its record', async () => {
    apiMocks.payrollFinalRecord.mockResolvedValueOnce({ final_record: { ...record, company: { id: 2, name: 'Other client' } } });
    render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    expect((await screen.findByRole('alert')).textContent).toContain('does not match the selected company and pay run');
    expect(screen.queryByText('$750.00 net')).toBeNull();
    expect(screen.queryByText('Other client')).toBeNull();
  });

  it.each(['refresh', 'run change', 'unmount'] as const)('discards a pending export after %s and permits fresh exports', async changed => {
    const createObjectURL = vi.fn(() => 'blob:current-record');
    vi.stubGlobal('URL', class extends URL { static createObjectURL = createObjectURL; static revokeObjectURL = vi.fn(); });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const old = deferred<{ blob: Blob }>();
    apiMocks.payrollFinalRecordPdf.mockReturnValueOnce(old.promise);
    const { rerender, unmount } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    await screen.findByText('$750.00 net');
    fireEvent.click(screen.getByRole('button', { name: 'PDF record (.pdf)' }));
    if (changed === 'unmount') unmount();
    else {
      apiMocks.payrollFinalRecord.mockResolvedValueOnce({ final_record: {
        ...voidedFinalRecordFixture, pay_period: { ...voidedFinalRecordFixture.pay_period, id: changed === 'run change' ? 9 : 8 },
      } });
      rerender(<PayrollFinalRecordPanel companyId={1} payPeriodId={changed === 'run change' ? 9 : 8} refreshToken={1} />);
      await screen.findByText('Voided');
    }
    await act(async () => old.resolve({ blob: new Blob(['obsolete']) }));
    expect(createObjectURL).not.toHaveBeenCalled();
    if (changed !== 'unmount') {
      apiMocks.payrollFinalRecordPdf.mockResolvedValueOnce({ blob: new Blob(['current']) });
      fireEvent.click(screen.getByRole('button', { name: 'PDF record (.pdf)' }));
      await waitFor(() => expect(createObjectURL).toHaveBeenCalledOnce());
      expect(HTMLAnchorElement.prototype.click).toHaveBeenCalledOnce();
    }
  });

  it('ignores an obsolete export failure while the current revision export is pending', async () => {
    const createObjectURL = vi.fn(() => 'blob:current-record');
    vi.stubGlobal('URL', class extends URL { static createObjectURL = createObjectURL; static revokeObjectURL = vi.fn(); });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const old = deferred<{ blob: Blob }>();
    const current = deferred<{ blob: Blob }>();
    apiMocks.payrollFinalRecordPdf.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    const { rerender } = render(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} />);
    await screen.findByText('$750.00 net');
    fireEvent.click(screen.getByRole('button', { name: 'PDF record (.pdf)' }));
    apiMocks.payrollFinalRecord.mockResolvedValueOnce({ final_record: voidedFinalRecordFixture });
    rerender(<PayrollFinalRecordPanel companyId={1} payPeriodId={8} refreshToken={1} />);
    await screen.findByText('Voided');
    fireEvent.click(screen.getByRole('button', { name: 'PDF record (.pdf)' }));
    await act(async () => old.reject(new Error('Old export failed')));
    expect(screen.queryByRole('alert')).toBeNull();
    expect((screen.getByRole('button', { name: 'PDF record (.pdf)' }) as HTMLButtonElement).disabled).toBe(true);
    expect(createObjectURL).not.toHaveBeenCalled();
    await act(async () => current.resolve({ blob: new Blob(['current']) }));
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect((screen.getByRole('button', { name: 'PDF record (.pdf)' }) as HTMLButtonElement).disabled).toBe(false);
  });
});
