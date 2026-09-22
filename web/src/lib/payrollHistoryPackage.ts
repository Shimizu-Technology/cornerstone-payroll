import JSZip from 'jszip';
import type { BlobDownload, PayrollHistoryRecord, PayrollRegisterReport } from '@/services/api';

export type PayrollHistoryPackageFormat = 'xlsx' | 'pdf';

interface PayrollHistoryPackageOptions {
  runs: PayrollHistoryRecord[];
  format: PayrollHistoryPackageFormat;
  fetchReport: (runKey: string) => Promise<PayrollRegisterReport>;
  fetchFile: (runKey: string) => Promise<BlobDownload>;
  generatedAt?: Date;
}

interface PayrollHistoryManifestRow {
  pay_run_key: string;
  source: string;
  status: string;
  work_period_start: string;
  work_period_end: string;
  pay_date: string;
  w2_employee_count: number;
  contractor_count: number;
  w2_gross: number;
  contractor_gross: number;
  combined_gross: number;
  w2_net: number;
  contractor_net: number;
  combined_net: number;
  report_file: string;
}

const MANIFEST_HEADERS: Array<[keyof PayrollHistoryManifestRow, string]> = [
  ['pay_run_key', 'Pay run key'],
  ['source', 'Source'],
  ['status', 'Status'],
  ['work_period_start', 'Work period start'],
  ['work_period_end', 'Work period end'],
  ['pay_date', 'Pay date'],
  ['w2_employee_count', 'W-2 employees'],
  ['contractor_count', '1099 contractors'],
  ['w2_gross', 'W-2 gross'],
  ['contractor_gross', '1099 gross'],
  ['combined_gross', 'Combined gross'],
  ['w2_net', 'W-2 net'],
  ['contractor_net', '1099 net'],
  ['combined_net', 'Combined net'],
  ['report_file', 'Report file'],
];

function safeFilename(value: string): string {
  const basename = value.split(/[\\/]/).pop() || 'payroll_register';
  return basename.replace(/[^A-Za-z0-9._-]/g, '_');
}

function slug(value: string): string {
  return value.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'company';
}

function csvCell(value: string | number): string {
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function manifestCsv(rows: PayrollHistoryManifestRow[]): string {
  const lines = [MANIFEST_HEADERS.map(([, label]) => csvCell(label)).join(',')];
  for (const row of rows) {
    lines.push(MANIFEST_HEADERS.map(([key]) => csvCell(row[key])).join(','));
  }
  return `${lines.join('\r\n')}\r\n`;
}

function manifestRow(report: PayrollRegisterReport['report'], path: string, fallbackKey: string): PayrollHistoryManifestRow {
  const summary = report.summary;
  const w2Gross = Number(summary.total_gross || 0);
  const contractorGross = Number(summary.contractor_total_gross || 0);
  const w2Net = Number(summary.total_net || 0);
  const contractorNet = Number(summary.contractor_total_net || 0);
  return {
    pay_run_key: report.pay_period.key || fallbackKey,
    source: report.source?.label || 'Unknown',
    status: report.pay_period.status,
    work_period_start: report.pay_period.start_date,
    work_period_end: report.pay_period.end_date,
    pay_date: report.pay_period.pay_date,
    w2_employee_count: Number(summary.employee_count || 0),
    contractor_count: Number(summary.contractor_count || 0),
    w2_gross: w2Gross,
    contractor_gross: contractorGross,
    combined_gross: w2Gross + contractorGross,
    w2_net: w2Net,
    contractor_net: contractorNet,
    combined_net: w2Net + contractorNet,
    report_file: path,
  };
}

/** Builds the complete history archive in the browser so one long export cannot occupy a web request thread. */
export async function buildPayrollHistoryPackage({
  runs,
  format,
  fetchReport,
  fetchFile,
  generatedAt = new Date(),
}: PayrollHistoryPackageOptions): Promise<{ blob: Blob; filename: string }> {
  if (runs.length === 0) throw new Error('No reportable payroll runs were found');

  const orderedRuns = [...runs].sort((left, right) =>
    left.pay_date.localeCompare(right.pay_date) || left.start_date.localeCompare(right.start_date) || left.key.localeCompare(right.key));
  const zip = new JSZip();
  const manifestRows: PayrollHistoryManifestRow[] = [];
  let companyName = 'Company';

  for (const [index, run] of orderedRuns.entries()) {
    const [reportResponse, file] = await Promise.all([fetchReport(run.key), fetchFile(run.key)]);
    const report = reportResponse.report;
    companyName = report.meta.company_name || companyName;
    const fallbackName = `payroll_register_${run.start_date}_to_${run.end_date}.${format}`;
    const reportPath = `reports/${String(index + 1).padStart(3, '0')}_${run.key.replace(':', '-')}_${safeFilename(file.filename || fallbackName)}`;
    zip.file(reportPath, new Uint8Array(await file.blob.arrayBuffer()));
    manifestRows.push(manifestRow(report, reportPath, run.key));
  }

  const generatedAtIso = generatedAt.toISOString();
  const manifest = {
    company: companyName,
    generated_at: generatedAtIso,
    report_format: format,
    payroll_run_count: manifestRows.length,
    payroll_runs: manifestRows,
  };
  zip.file('manifest.csv', manifestCsv(manifestRows));
  zip.file('manifest.json', JSON.stringify(manifest, null, 2));
  zip.file('README.txt', [
    `Complete payroll history for ${companyName}`,
    '',
    `This package contains one ${format.toUpperCase()} payroll register for every reportable payroll run,`,
    'plus CSV and JSON manifests for reconciliation. W-2 employees and 1099 contractors are kept',
    'in separate report sections. The manifest reports each group separately and also provides',
    'combined gross and net totals.',
    '',
    'Date meanings:',
    '- Work period start/end: when the work was performed.',
    '- Pay date: when the payroll was paid. Tax and cumulative payroll reports use pay date.',
    '',
    `Generated: ${generatedAtIso}`,
    '',
  ].join('\n'));

  return {
    blob: await zip.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } }),
    filename: `payroll_history_${slug(companyName)}_${generatedAtIso.slice(0, 10)}.zip`,
  };
}
