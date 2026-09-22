import { describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import { buildPayrollHistoryPackage } from './payrollHistoryPackage';
import type { PayrollHistoryRecord, PayrollRegisterReport } from '@/services/api';

describe('buildPayrollHistoryPackage', () => {
  it('packages each run with separate W-2 and 1099 reconciliation totals', async () => {
    const run = {
      key: 'native:42', start_date: '2026-04-01', end_date: '2026-04-15', pay_date: '2026-04-30',
    } as PayrollHistoryRecord;
    const report = {
      meta: { company_name: 'AIRE Services' },
      source: { label: 'Cornerstone' },
      pay_period: { key: run.key, id: 42, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date, status: 'committed' },
      summary: { employee_count: 2, contractor_count: 1, total_gross: 1_000, contractor_total_gross: 600, total_net: 249.34, contractor_total_net: 249 },
    } as PayrollRegisterReport['report'];
    const fetchReport = vi.fn().mockResolvedValue({ report });
    const fetchFile = vi.fn().mockResolvedValue({ blob: new Blob(['workbook']), filename: 'register.xlsx' });

    const result = await buildPayrollHistoryPackage({
      runs: [run], format: 'xlsx', fetchReport, fetchFile, generatedAt: new Date('2026-09-22T02:00:00Z'),
    });
    const archive = await JSZip.loadAsync(new Uint8Array(await result.blob.arrayBuffer()));
    const manifest = JSON.parse(await archive.file('manifest.json')!.async('string'));

    expect(result.filename).toBe('payroll_history_aire-services_2026-09-22.zip');
    expect(Object.keys(archive.files)).toEqual(expect.arrayContaining([
      'README.txt', 'manifest.csv', 'manifest.json', 'reports/001_native-42_register.xlsx',
    ]));
    expect(manifest).toMatchObject({ company: 'AIRE Services', report_format: 'xlsx', payroll_run_count: 1 });
    expect(manifest.payroll_runs[0]).toMatchObject({
      pay_run_key: 'native:42', w2_employee_count: 2, contractor_count: 1,
      combined_gross: 1_600, w2_net: 249.34, contractor_net: 249, combined_net: 498.34,
    });
    expect(await archive.file('reports/001_native-42_register.xlsx')!.async('string')).toBe('workbook');
  });

  it('rejects an empty payroll history', async () => {
    await expect(buildPayrollHistoryPackage({
      runs: [], format: 'pdf', fetchReport: vi.fn(), fetchFile: vi.fn(),
    })).rejects.toThrow('No reportable payroll runs');
  });

  it('rounds currency ties symmetrically and combined raw values only once', async () => {
    const run = {
      key: 'native:43', start_date: '2026-04-16', end_date: '2026-04-30', pay_date: '2026-05-15',
    } as PayrollHistoryRecord;
    const report = {
      meta: { company_name: 'AIRE Services' },
      source: { label: 'Cornerstone' },
      pay_period: { key: run.key, id: 43, start_date: run.start_date, end_date: run.end_date, pay_date: run.pay_date, status: 'committed' },
      summary: {
        employee_count: 1, contractor_count: 1,
        total_gross: 0.004, contractor_total_gross: 0.004,
        total_net: 10.075, contractor_total_net: -10.075,
      },
    } as PayrollRegisterReport['report'];

    const result = await buildPayrollHistoryPackage({
      runs: [run],
      format: 'xlsx',
      fetchReport: vi.fn().mockResolvedValue({ report }),
      fetchFile: vi.fn().mockResolvedValue({ blob: new Blob(['workbook']), filename: 'register.xlsx' }),
      generatedAt: new Date('2026-09-22T02:00:00Z'),
    });
    const archive = await JSZip.loadAsync(new Uint8Array(await result.blob.arrayBuffer()));
    const manifest = JSON.parse(await archive.file('manifest.json')!.async('string'));
    const row = manifest.payroll_runs[0];

    expect(row).toMatchObject({
      w2_gross: 0, contractor_gross: 0, combined_gross: 0.01,
      w2_net: 10.08, contractor_net: -10.08, combined_net: 0,
    });
    expect(Object.is(row.combined_net, -0)).toBe(false);
  });
});
