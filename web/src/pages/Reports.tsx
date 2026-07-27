import { useState, useEffect, useMemo, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Link, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { reportsApi, payPeriodsApi, employeesApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import { comparePayPeriodsByPeriod } from '@/lib/utils';
import { PayrollRegisterPreviewContent } from '@/components/reports/PayrollRegisterPreview';
import { ReportDownloadMenu, type ReportDownloadFormat } from '@/components/reports/ReportDownloadMenu';
import type { PayrollRegisterReport, TaxSummaryReport, YtdSummaryReport, Form941GuReport, QuarterlyCompliancePacketReport, QuarterlyComplianceTask, QuarterlyOfficialFormFields, QuarterlyOfficialFormType, YtdSummaryParams, PayrollFieldsDisclosure, PayrollReportPeriodParams } from '@/services/api';
import type {
  PayPeriod,
  Employee,
  W2GuReport,
  W2GuEmployeeRow,
  W2GuPreflightResult,
  W2GuFilingReadiness,
  W2GuMarkReadyResponse,
} from '@/types';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmt(n: number) {
  return n.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

function extractErrorMessage(err: unknown): string {
  if (err instanceof Error && err.message) return err.message;
  if (typeof err === 'object' && err !== null) {
    const maybeErr = err as { message?: unknown; error?: unknown };
    if (typeof maybeErr.message === 'string' && maybeErr.message.length > 0) return maybeErr.message;
    if (typeof maybeErr.error === 'string' && maybeErr.error.length > 0) return maybeErr.error;
  }
  return 'An error occurred';
}

function triggerDownload(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 100);
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-medium uppercase text-gray-500">{label}</span>
      {children}
    </label>
  );
}

function SortableTh({
  label,
  activeLabel,
  align = 'left',
  onClick,
}: {
  label: string;
  activeLabel: string;
  align?: 'left' | 'right';
  onClick: () => void;
}) {
  return (
    <th className={`pb-2 pr-4 font-medium ${align === 'right' ? 'text-right' : 'text-left'}`}>
      <button
        type="button"
        className={`text-xs font-medium uppercase tracking-wide text-gray-500 hover:text-gray-900 ${align === 'right' ? 'text-right' : 'text-left'}`}
        onClick={onClick}
      >
        {label}{activeLabel}
      </button>
    </th>
  );
}

function buildRevalidationPreflight(revalidation: W2GuMarkReadyResponse['revalidation']): W2GuPreflightResult | null {
  if (!revalidation) return null;

  return {
    year: revalidation.year,
    company_id: revalidation.company_id,
    company_name: revalidation.company_name,
    run_at: revalidation.run_at,
    blocking_count: revalidation.blocking_count,
    warning_count: revalidation.warning_count,
    findings: revalidation.findings,
  };
}

// ─── Payroll Register Panel ───────────────────────────────────────────────────

function PayrollRegisterPanel() {
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loadingPeriods, setLoadingPeriods] = useState(true);
  const [selectedPeriodId, setSelectedPeriodId] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<PayrollRegisterReport['report'] | null>(null);

  useEffect(() => {
    payPeriodsApi.list({ status: 'committed' })
      .then((res) => {
        const periods = res.pay_periods ?? [];
        const sorted = [...periods].sort((a, b) => comparePayPeriodsByPeriod(a, b, 'desc'));
        setPayPeriods(sorted);
        if (sorted.length > 0) setSelectedPeriodId(sorted[0].id);
      })
      .catch(() => setError('Failed to load pay periods'))
      .finally(() => setLoadingPeriods(false));
  }, []);

  const busy = loading || exportingCsv || exportingPdf || exportingXlsx;
  const downloadFormats: ReportDownloadFormat[] = [
    {
      key: 'xlsx',
      label: 'Excel register (.xlsx)',
      description: 'CEO-facing register with split tips and review details.',
      kind: 'data',
      loading: exportingXlsx,
      onSelect: downloadXlsx,
    },
    {
      key: 'pdf',
      label: 'Detailed PDF (.pdf)',
      description: 'Printable detailed payroll report.',
      kind: 'pdf',
      loading: exportingPdf,
      onSelect: downloadPdf,
    },
    {
      key: 'csv',
      label: 'Data export (.csv)',
      description: 'Raw payroll register rows for data workflows.',
      kind: 'spreadsheet',
      loading: exportingCsv,
      onSelect: downloadCsv,
    },
  ];

  async function loadReport() {
    if (!selectedPeriodId) return;
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.payrollRegister(selectedPeriodId);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }


  async function downloadCsv() {
    if (!selectedPeriodId) return;
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.payrollRegisterCsv(selectedPeriodId);
      triggerDownload(blob, filename || `payroll_register_${selectedPeriodId}.csv`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  async function downloadPdf() {
    if (!selectedPeriodId) return;
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.payrollRegisterPdf(selectedPeriodId);
      triggerDownload(blob, filename || `payroll_register_${selectedPeriodId}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadXlsx() {
    if (!selectedPeriodId) return;
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.payrollRegisterXlsx(selectedPeriodId);
      triggerDownload(blob, filename || `payroll_register_${selectedPeriodId}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Payroll Register</CardTitle>
          <CardDescription>
            Complete payroll details for a selected pay period — all employees, hours, taxes, and net pay.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="pr-period" className="text-sm font-medium text-gray-700">
                Pay Period
              </label>
              {loadingPeriods ? (
                <span className="text-sm text-gray-400">Loading…</span>
              ) : (
                <select
                  id="pr-period"
                  value={selectedPeriodId ?? ''}
                  onChange={(e) => {
                    setSelectedPeriodId(Number(e.target.value));
                    setReport(null);
                    setError(null);
                  }}
                  disabled={busy}
                  className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
                >
                  {payPeriods.length === 0 && <option value="">No committed pay periods</option>}
                  {payPeriods.map((pp) => (
                    <option key={pp.id} value={pp.id}>
                      {pp.start_date} – {pp.end_date} (Pay: {pp.pay_date})
                    </option>
                  ))}
                </select>
              )}
            </div>
            <Button onClick={loadReport} disabled={busy || !selectedPeriodId}>
              {loading ? 'Loading…' : 'View Report'}
            </Button>
            <div className="grid w-full grid-cols-1 gap-2 sm:ml-auto sm:flex sm:w-auto sm:items-center sm:gap-2">
              <ReportDownloadMenu formats={downloadFormats} disabled={busy || !selectedPeriodId} />
            </div>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && <PayrollRegisterPreviewContent report={report} />}
    </div>
  );
}

function ChecksPaymentsRegisterPanel() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Checks & Payments Register</CardTitle>
        <CardDescription>
          Review and export standalone checks for GRT, estimated tax, vendors, reimbursements,
          and other payments that are not tied to a payroll period.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Link
          to="/checks-payments"
          className="inline-flex items-center justify-center rounded-xl bg-primary-600 px-4 py-2.5 text-sm font-medium text-white shadow-sm transition-colors hover:bg-primary-700"
        >
          Open Checks & Payments
        </Link>
        <p className="mt-3 text-sm text-gray-500">
          Use the register filters, then choose Export Register to download the visible checks as CSV.
        </p>
      </CardContent>
    </Card>
  );
}

// ─── Tax Summary Panel ────────────────────────────────────────────────────────

function TaxSummaryPanel() {
  const currentYear = new Date().getFullYear();
  const earliestSupportedYear = 2020;
  const yearOptions = Array.from(
    { length: currentYear - earliestSupportedYear + 1 },
    (_, i) => currentYear - i
  );
  const [year, setYear] = useState(currentYear);
  const [quarter, setQuarter] = useState<number | undefined>(undefined);
  const [periodMode, setPeriodMode] = useState<'calendar' | 'custom'>('calendar');
  const [startDate, setStartDate] = useState(`${currentYear}-01-01`);
  const [endDate, setEndDate] = useState(new Date().toISOString().slice(0, 10));
  const [loading, setLoading] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TaxSummaryReport['report'] | null>(null);

  const busy = loading || exportingCsv || exportingPdf || exportingXlsx;
  const periodParams = periodMode === 'custom'
    ? { start_date: startDate, end_date: endDate }
    : { year, quarter };

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.taxSummary(periodParams);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }


  async function downloadCsv() {
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryCsv(periodParams);
      triggerDownload(blob, filename || `tax_summary_${year}${quarter ? `_q${quarter}` : ''}.csv`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryPdf(periodParams);
      triggerDownload(blob, filename || `tax_summary_${year}${quarter ? `_q${quarter}` : ''}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryXlsx(periodParams);
      triggerDownload(blob, filename || `tax_summary_${year}${quarter ? `_q${quarter}` : ''}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  const periodLabel = periodMode === 'custom' ? `${startDate} – ${endDate}` : (quarter ? `Q${quarter} ${year}` : `${year} Full Year`);
  const exportFormats: ReportDownloadFormat[] = [
    {
      key: 'pdf',
      label: 'PDF',
      description: 'Print-ready report for review or sharing',
      kind: 'pdf',
      loading: exportingPdf,
      onSelect: downloadPdf,
    },
    {
      key: 'xlsx',
      label: 'Excel workbook',
      description: 'Formatted workbook for analysis',
      kind: 'spreadsheet',
      loading: exportingXlsx,
      onSelect: downloadXlsx,
    },
    {
      key: 'csv',
      label: 'CSV data',
      description: 'Portable row data for other systems',
      kind: 'data',
      loading: exportingCsv,
      onSelect: downloadCsv,
    },
  ];

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Tax Withholding Summary</CardTitle>
          <CardDescription>
            Quarterly tax withholding totals for filing preparation — all committed pay periods in range.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="ts-period-mode" className="text-sm font-medium text-gray-700">Period</label>
              <select id="ts-period-mode" value={periodMode} onChange={(e) => { setPeriodMode(e.target.value as 'calendar' | 'custom'); setReport(null); setError(null); }} className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm">
                <option value="calendar">Year / quarter</option>
                <option value="custom">Custom pay dates</option>
              </select>
            </div>
            {periodMode === 'custom' ? (
              <>
                <input aria-label="Tax summary start date" type="date" value={startDate} onChange={(e) => { setStartDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
                <span className="text-sm text-gray-500">to</span>
                <input aria-label="Tax summary end date" type="date" value={endDate} onChange={(e) => { setEndDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
              </>
            ) : <>
            <div className="flex items-center gap-2">
              <label htmlFor="ts-year" className="text-sm font-medium text-gray-700">Year</label>
              <select
                id="ts-year"
                value={year}
                onChange={(e) => {
                  setYear(Number(e.target.value));
                  setReport(null);
                  setError(null);
                }}
                disabled={busy}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            </>}
            {periodMode === 'calendar' && (
              <div className="flex items-center gap-2">
                <label htmlFor="ts-quarter" className="text-sm font-medium text-gray-700">Quarter</label>
                <select
                  id="ts-quarter"
                  value={quarter ?? ''}
                  onChange={(e) => {
                    setQuarter(e.target.value ? Number(e.target.value) : undefined);
                    setReport(null);
                    setError(null);
                  }}
                  disabled={busy}
                  className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
                >
                  <option value="">Full Year</option>
                  <option value="1">Q1 (Jan–Mar)</option>
                  <option value="2">Q2 (Apr–Jun)</option>
                  <option value="3">Q3 (Jul–Sep)</option>
                  <option value="4">Q4 (Oct–Dec)</option>
                </select>
              </div>
            )}
            <Button onClick={loadReport} disabled={busy}>
              {loading ? 'Loading…' : 'View Report'}
            </Button>
            <div className="sm:ml-auto">
              <ReportDownloadMenu
                formats={exportFormats}
                disabled={busy}
                ariaLabel={`Export Tax Summary for ${periodLabel}`}
              />
            </div>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <Card>
          <CardHeader>
            <CardTitle>
              Tax Summary — {periodLabel}
            </CardTitle>
            <CardDescription>
              Pay-date basis &bull; {report.pay_periods_included} pay period{report.pay_periods_included !== 1 ? 's' : ''} &bull;{' '}
              {report.employee_count} employee{report.employee_count !== 1 ? 's' : ''}
              {report.period.start_date && (
                <> &bull; {report.period.start_date} – {report.period.end_date}</>
              )}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
              <TotalBox label="Gross Wages" value={report.totals.gross_wages} />
              <TotalBox label="Withholding Tax" value={report.totals.withholding_tax} />
              <TotalBox label="SS Tax (Employee)" value={report.totals.social_security_employee} />
              <TotalBox label="SS Tax (Employer)" value={report.totals.social_security_employer} />
              <TotalBox label="Medicare (Employee)" value={report.totals.medicare_employee} />
              <TotalBox label="Medicare (Employer)" value={report.totals.medicare_employer} />
              <TotalBox label="Total Employment Taxes" value={report.totals.total_employment_taxes} />
            </div>
            <PayrollFieldTotalsTable disclosure={report.payroll_fields} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

// ─── W-2GU Panel ─────────────────────────────────────────────────────────────

function W2GuPanel() {
  const currentYear = new Date().getFullYear();
  const earliestSupportedYear = 2020;
  const selectableMaxYear = currentYear + 1;
  const yearOptions = Array.from(
    { length: selectableMaxYear - earliestSupportedYear + 1 },
    (_, i) => selectableMaxYear - i
  );
  const [year, setYear] = useState(currentYear - 1);
  const [loading, setLoading] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<W2GuReport | null>(null);
  const [preflightLoading, setPreflightLoading] = useState(false);
  const [preflight, setPreflight] = useState<W2GuPreflightResult | null>(null);
  const [filing, setFiling] = useState<W2GuFilingReadiness | null>(null);
  const [preflightError, setPreflightError] = useState<string | null>(null);
  const [markReadyError, setMarkReadyError] = useState<string | null>(null);
  const [markingReady, setMarkingReady] = useState(false);
  const [filingNotes, setFilingNotes] = useState('');

  useEffect(() => {
    void loadPersistedFilingReadiness();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [year]);

  async function loadPersistedFilingReadiness() {
    try {
      const res = await reportsApi.w2GuFilingReadiness(year);
      setFiling(res.filing);
    } catch {
      // Non-blocking: filing readiness can be absent or temporarily unavailable.
      setFiling(null);
    }
  }

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.w2Gu(year);
      setReport(res.report);
    } catch (err: unknown) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function runPreflight() {
    setPreflightLoading(true);
    setPreflightError(null);
    setMarkReadyError(null);
    try {
      const res = await reportsApi.w2GuPreflight(year);
      setPreflight(res.preflight);
      setFiling(res.filing);
    } catch (err: unknown) {
      setPreflightError(extractErrorMessage(err));
    } finally {
      setPreflightLoading(false);
    }
  }

  async function markFilingReady() {
    setMarkingReady(true);
    setMarkReadyError(null);
    try {
      const res = await reportsApi.w2GuMarkReady(year, filingNotes);
      setFiling(res.filing);
      const revalidatedPreflight = buildRevalidationPreflight(res.revalidation);
      if (revalidatedPreflight) {
        setPreflight(revalidatedPreflight);
      } else {
        setPreflight(null);
      }
      setPreflightError(null);
      setFilingNotes('');
    } catch (err: unknown) {
      let revalidated = false;
      if (err instanceof ApiError && err.data && typeof err.data === 'object') {
        const errorData = err.data as Partial<W2GuMarkReadyResponse>;

        if (errorData.filing) {
          setFiling(errorData.filing);
        }

        const revalidatedPreflight = buildRevalidationPreflight(errorData.revalidation);
        if (revalidatedPreflight) {
          setPreflight(revalidatedPreflight);
          revalidated = true;
        }
      }
      if (!revalidated) {
        setPreflight(null);
      }
      setMarkReadyError(extractErrorMessage(err));
    } finally {
      setMarkingReady(false);
    }
  }

  async function downloadCsv() {
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.w2GuCsv(year);
      triggerDownload(blob, filename || `w2gu_${year}.csv`);
    } catch (err: unknown) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.w2GuPdf(year);
      triggerDownload(blob, filename || `w2gu_${year}.pdf`);
    } catch (err: unknown) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.w2GuXlsx(year);
      triggerDownload(blob, filename || `w2gu_${year}.xlsx`);
    } catch (err: unknown) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  const busy = loading || exportingCsv || exportingPdf || exportingXlsx || preflightLoading || markingReady;
  const exportFormats: ReportDownloadFormat[] = [
    {
      key: 'pdf',
      label: 'PDF',
      description: 'Print-ready annual report',
      kind: 'pdf',
      loading: exportingPdf,
      onSelect: downloadPdf,
    },
    {
      key: 'xlsx',
      label: 'Excel workbook',
      description: 'Formatted annual workbook',
      kind: 'spreadsheet',
      loading: exportingXlsx,
      onSelect: downloadXlsx,
    },
    {
      key: 'csv',
      label: 'CSV data',
      description: 'Portable employee filing data',
      kind: 'data',
      loading: exportingCsv,
      onSelect: downloadCsv,
    },
  ];

  return (
    <div className="space-y-6">
      {/* Controls */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">W-2GU Annual Report</CardTitle>
          <CardDescription>
            Guam Territorial W-2 preparation summary — review before filing with DRT.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="w2gu-year" className="text-sm font-medium text-gray-700">
                Tax Year
              </label>
              <select
                id="w2gu-year"
                value={year}
                onChange={(e) => {
                  setYear(Number(e.target.value));
                  setReport(null);
                  setError(null);
                  setPreflight(null);
                  setFiling(null);
                  setPreflightError(null);
                  setMarkReadyError(null);
                  setFilingNotes('');
                }}
                disabled={busy}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            <Button onClick={loadReport} disabled={busy}>
              {loading ? 'Loading…' : 'View W-2GU Report'}
            </Button>

            <Button variant="outline" onClick={runPreflight} disabled={busy}>
              {preflightLoading ? 'Running Preflight…' : 'Run Preflight'}
            </Button>
            <Button
              onClick={markFilingReady}
              disabled={busy || !filing || filing.blocking_count > 0 || filing.status === 'filing_ready'}
              title={
                !filing
                  ? 'Run preflight first'
                  : filing.status === 'filing_ready'
                    ? 'Already marked filing ready'
                    : filing.blocking_count > 0
                      ? 'Resolve blocking findings before marking ready'
                      : 'Mark filing as ready for submission'
              }
            >
              {markingReady ? 'Marking…' : 'Mark Filing Ready'}
            </Button>

            <div className="sm:ml-auto">
              <ReportDownloadMenu
                formats={exportFormats}
                disabled={busy}
                ariaLabel={`Export W-2GU report for ${year}`}
              />
            </div>
          </div>
          <div className="mt-3">
            <label htmlFor="w2gu-filing-notes" className="block text-sm font-medium text-gray-700 mb-1">
              Filing Notes (optional)
            </label>
            <textarea
              id="w2gu-filing-notes"
              value={filingNotes}
              onChange={(e) => setFilingNotes(e.target.value)}
              disabled={busy || filing?.status === 'filing_ready'}
              placeholder="Add operator notes before marking filing ready"
              className="w-full min-h-[72px] rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
            />
          </div>
          {error && (
            <p className="mt-3 text-sm text-red-600">{error}</p>
          )}
        </CardContent>
      </Card>

      {preflightError && (
        <Card>
          <CardContent className="pt-6">
            <p className="text-sm font-medium text-red-700">Preflight Error</p>
            <p className="text-sm text-red-600 mt-1">{preflightError}</p>
          </CardContent>
        </Card>
      )}

      {markReadyError && (
        <Card>
          <CardContent className="pt-6">
            <p className="text-sm font-medium text-red-700">Mark Ready Error</p>
            <p className="text-sm text-red-600 mt-1">{markReadyError}</p>
            <p className="text-xs text-gray-600 mt-2">Re-run preflight to view the latest blocking findings.</p>
          </CardContent>
        </Card>
      )}

      {filing && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Filing Readiness</CardTitle>
            <CardDescription>
              Status: <span className="font-medium">{filing.status}</span> • Blocking: {filing.blocking_count} • Warnings: {filing.warning_count}
            </CardDescription>
            {filing.preflight_run_at && (
              <p className="text-xs text-gray-500">
                Last explicit preflight: {new Date(filing.preflight_run_at).toLocaleString()}
              </p>
            )}
            {filing.marked_ready_at && (
              <p className="text-xs text-gray-500">
                Marked ready: {new Date(filing.marked_ready_at).toLocaleString()}
                {typeof filing.marked_ready_by_id === 'number' ? ` (user #${filing.marked_ready_by_id})` : ''}
              </p>
            )}
            {filing.notes && <p className="text-sm text-gray-600">Notes: {filing.notes}</p>}
          </CardHeader>
        </Card>
      )}

      {preflight && preflight.findings.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Preflight Findings</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {preflight.findings.slice(0, 25).map((f, i) => (
              <p key={i} className={f.severity === 'blocking' ? 'text-sm text-red-700' : 'text-sm text-amber-700'}>
                • [{f.severity}] {f.message}
              </p>
            ))}
            {preflight.findings.length > 25 && (
              <p className="text-xs text-gray-500">Showing first 25 of {preflight.findings.length} findings.</p>
            )}
          </CardContent>
        </Card>
      )}

      {/* Results */}
      {report && (
        <>
          {/* Summary */}
          <Card>
            <CardHeader>
              <div className="flex items-start justify-between">
                <div>
                  <CardTitle>
                    {report.meta.company_name} — {report.meta.year} W-2GU Summary
                  </CardTitle>
                  <CardDescription className="mt-1">
                    {report.meta.employee_count} employee{report.meta.employee_count !== 1 ? 's' : ''} &bull; Generated {new Date(report.meta.generated_at).toLocaleString()}
                  </CardDescription>
                </div>
                {report.compliance_issues.length > 0 && (
                  <Badge variant="danger">{report.compliance_issues.length} Compliance Issue{report.compliance_issues.length !== 1 ? 's' : ''}</Badge>
                )}
              </div>
            </CardHeader>
            <CardContent className="space-y-4">
              {/* Compliance issues */}
              {report.compliance_issues.length > 0 && (
                <div className="rounded-md bg-red-50 border border-red-200 p-3 space-y-1">
                  <p className="text-sm font-medium text-red-700">Compliance Issues</p>
                  {report.compliance_issues.map((issue, i) => (
                    <p key={i} className="text-sm text-red-600">• {issue}</p>
                  ))}
                </div>
              )}

              {/* Totals grid */}
              <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                <TotalBox label="Box 1 — Wages, Tips & Other Comp" value={report.totals.box1_wages_tips_other_comp} />
                <TotalBox label="Box 2 — Federal Income Tax Withheld" value={report.totals.box2_federal_income_tax_withheld} />
                <TotalBox label="Box 3 — Social Security Wages" value={report.totals.box3_social_security_wages} />
                <TotalBox label="Box 4 — SS Tax Withheld" value={report.totals.box4_social_security_tax_withheld} />
                <TotalBox label="Box 5 — Medicare Wages & Tips" value={report.totals.box5_medicare_wages_tips} />
                <TotalBox label="Box 6 — Medicare Tax Withheld" value={report.totals.box6_medicare_tax_withheld} />
                <TotalBox label="Box 7 — Social Security Tips" value={report.totals.box7_social_security_tips} />
                <TotalBox label="Reported Tips (Uncapped)" value={report.totals.reported_tips_total} />
              </div>

              {/* Caveats */}
              <div className="rounded-md bg-amber-50 border border-amber-200 p-3 space-y-1">
                <p className="text-sm font-medium text-amber-800">Notes</p>
                {report.meta.caveats.map((c, i) => (
                  <p key={i} className="text-sm text-amber-700">• {c}</p>
                ))}
              </div>
            </CardContent>
          </Card>

          {/* Employee Table */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Employee Detail</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-gray-500">
                    <th className="pb-2 pr-4 font-medium">Employee</th>
                    <th className="pb-2 pr-4 font-medium">SSN</th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 1<br /><span className="font-normal text-xs">Wages</span></th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 2<br /><span className="font-normal text-xs">Fed W/H</span></th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 3<br /><span className="font-normal text-xs">SS Wages</span></th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 4<br /><span className="font-normal text-xs">SS W/H</span></th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 5<br /><span className="font-normal text-xs">Medicare Wages</span></th>
                    <th className="pb-2 pr-4 font-medium text-right">Box 6<br /><span className="font-normal text-xs">Medicare</span></th>
                    <th className="pb-2 font-medium text-right">Box 7<br /><span className="font-normal text-xs">SS Tips</span></th>
                  </tr>
                </thead>
                <tbody>
                  {report.employees.map((emp: W2GuEmployeeRow) => (
                    <tr key={emp.employee_id} className="border-b last:border-0 hover:bg-gray-50">
                      <td className="py-2 pr-4">
                        <div className="flex items-center gap-2">
                          <span>{emp.employee_name}</span>
                          {emp.has_missing_ssn && (
                            <Badge variant="danger" className="text-xs py-0">No SSN</Badge>
                          )}
                        </div>
                      </td>
                      <td className="py-2 pr-4 font-mono text-gray-500">
                        {emp.employee_ssn_last4 ? `***-**-${emp.employee_ssn_last4}` : '—'}
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box1_wages_tips_other_comp)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box2_federal_income_tax_withheld)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box3_social_security_wages)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box4_social_security_tax_withheld)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box5_medicare_wages_tips)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.box6_medicare_tax_withheld)}</td>
                      <td className="py-2 text-right tabular-nums">
                        {fmt(emp.box7_social_security_tips)}
                        {emp.box7_limited_by_wage_base && (
                          <span
                            className="ml-2 text-xs text-amber-700"
                            title={`Reported tips ${fmt(emp.reported_tips_total)} exceeded remaining SS wage base; Box 7 capped at ${fmt(emp.box7_social_security_tips)}.`}
                          >
                            (capped)
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                  {report.employees.length === 0 && (
                    <tr>
                      <td colSpan={9} className="py-6 text-center text-gray-400">
                        No committed payroll data found for {report.meta.year}.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

// ─── Employee Pay History Panel ────────────────────────────────────────────

function EmployeePayHistoryPanel() {
  const currentYear = new Date().getFullYear();
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loadingEmployees, setLoadingEmployees] = useState(true);
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<{
    period: { label: string; start_date: string; end_date: string };
    employee: { id: number; name: string; employment_type: string; pay_rate: number };
    history: {
      pay_period_id: number;
      pay_date: string;
      period_description: string;
      hours_worked: number | null;
      overtime_hours: number | null;
      custom_earnings_total?: number;
      gross_pay: number;
      custom_deductions_total?: number;
      total_deductions: number;
      net_pay: number;
      check_number: string | null;
    }[];
    ytd: Record<string, number>;
    summary: Record<string, number>;
    payroll_fields: PayrollFieldsDisclosure;
  } | null>(null);
  const [startDate, setStartDate] = useState(`${currentYear}-01-01`);
  const [endDate, setEndDate] = useState(new Date().toISOString().slice(0, 10));
  const periodParams: PayrollReportPeriodParams = { start_date: startDate, end_date: endDate };

  useEffect(() => {
    async function loadAllEmployees() {
      try {
        const all: Employee[] = [];
        let page = 1;
        let hasMore = true;
        while (hasMore) {
          const res = await employeesApi.list({ status: 'active', per_page: 100, page });
          const batch = res.data ?? [];
          all.push(...batch);
          hasMore = batch.length === 100;
          page++;
        }
        all.sort((a, b) => (a.last_name || '').localeCompare(b.last_name || ''));
        setEmployees(all);
        if (all.length > 0) setSelectedEmployeeId(all[0].id);
      } catch {
        setError('Failed to load employees');
      } finally {
        setLoadingEmployees(false);
      }
    }
    loadAllEmployees();
  }, []);

  async function loadReport() {
    if (!selectedEmployeeId) return;
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.employeePayHistory(selectedEmployeeId, periodParams);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function downloadXlsx() {
    if (!selectedEmployeeId) return;
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.employeePayHistoryXlsx(selectedEmployeeId, periodParams);
      triggerDownload(blob, filename || `employee_pay_history_${selectedEmployeeId}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  async function downloadPdf() {
    if (!selectedEmployeeId) return;
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.employeePayHistoryPdf(selectedEmployeeId, periodParams);
      triggerDownload(blob, filename || `employee_pay_history_${selectedEmployeeId}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadCsv() {
    if (!selectedEmployeeId) return;
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.employeePayHistoryCsv(selectedEmployeeId, periodParams);
      triggerDownload(blob, filename || `employee_pay_history_${selectedEmployeeId}.csv`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  const exportFormats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'PDF report (.pdf)', description: 'Review-ready report for printing or sharing.', kind: 'pdf', loading: exportingPdf, onSelect: downloadPdf },
    { key: 'xlsx', label: 'Excel workbook (.xlsx)', description: 'Multi-sheet workbook for reconciliation.', kind: 'spreadsheet', loading: exportingXlsx, onSelect: downloadXlsx },
    { key: 'csv', label: 'History data (.csv)', description: 'Flat paycheck history for data workflows.', kind: 'data', loading: exportingCsv, onSelect: downloadCsv },
  ];

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Employee Pay History</CardTitle>
          <CardDescription>
            Individual employee pay records for an exact committed-payroll pay-date range.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="eph-employee" className="text-sm font-medium text-gray-700">
                Employee
              </label>
              {loadingEmployees ? (
                <span className="text-sm text-gray-400">Loading…</span>
              ) : (
                <select
                  id="eph-employee"
                  value={selectedEmployeeId ?? ''}
                  onChange={(e) => {
                    setSelectedEmployeeId(Number(e.target.value));
                    setReport(null);
                    setError(null);
                  }}
                  disabled={loading}
                  className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
                >
                  {employees.length === 0 && <option value="">No active employees</option>}
                  {employees.map((emp) => (
                    <option key={emp.id} value={emp.id}>
                      {emp.last_name}, {emp.first_name}
                    </option>
                  ))}
                </select>
              )}
            </div>
            <input aria-label="Employee history start date" type="date" value={startDate} onChange={(e) => { setStartDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
            <span className="text-sm text-gray-500">to</span>
            <input aria-label="Employee history end date" type="date" value={endDate} onChange={(e) => { setEndDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
            <Button onClick={loadReport} disabled={loading || !selectedEmployeeId}>
              {loading ? 'Loading…' : 'View Report'}
            </Button>
            <ReportDownloadMenu
              formats={exportFormats}
              disabled={loading || exportingPdf || exportingXlsx || exportingCsv || !selectedEmployeeId}
            />
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>{report.employee.name}</CardTitle>
              <CardDescription>
                {report.employee.employment_type} &bull; Rate: {fmt(report.employee.pay_rate)} &bull; Pay dates {report.period.label}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 mb-6">
                <TotalBox label="Gross Pay" value={report.summary.gross_pay ?? 0} />
                <TotalBox label="Custom Earnings" value={report.summary.custom_earnings_total ?? 0} />
                <TotalBox label="Withholding" value={report.summary.withholding_tax ?? 0} />
                <TotalBox label="SS Tax" value={report.summary.social_security_tax ?? 0} />
                <TotalBox label="Medicare" value={report.summary.medicare_tax ?? 0} />
                <TotalBox label="Retirement" value={report.summary.retirement ?? 0} />
                <TotalBox label="Custom Deductions" value={report.summary.custom_deductions_total ?? 0} />
                <TotalBox label="Deductions" value={report.summary.total_deductions ?? 0} />
                <TotalBox label="Net Pay" value={report.summary.net_pay ?? 0} />
              </div>
              <PayrollFieldTotalsTable disclosure={report.payroll_fields} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Pay Period History</CardTitle>
              <CardDescription>{report.history.length} period{report.history.length !== 1 ? 's' : ''}</CardDescription>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-gray-500">
                    <th className="pb-2 pr-4 font-medium">Pay Date</th>
                    <th className="pb-2 pr-4 font-medium">Period</th>
                    <th className="pb-2 pr-4 font-medium text-right">Hours</th>
                    <th className="pb-2 pr-4 font-medium text-right">OT Hours</th>
                    <th className="pb-2 pr-4 font-medium text-right">Custom Earn.</th>
                    <th className="pb-2 pr-4 font-medium text-right">Gross Pay</th>
                    <th className="pb-2 pr-4 font-medium text-right">Custom Ded.</th>
                    <th className="pb-2 pr-4 font-medium text-right">Deductions</th>
                    <th className="pb-2 pr-4 font-medium text-right">Net Pay</th>
                    <th className="pb-2 font-medium">Check #</th>
                  </tr>
                </thead>
                <tbody>
                  {report.history.map((h) => (
                    <tr key={h.pay_period_id} className="border-b last:border-0 hover:bg-gray-50">
                      <td className="py-2 pr-4">{h.pay_date}</td>
                      <td className="py-2 pr-4 text-gray-500">{h.period_description}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{h.hours_worked ?? '—'}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{h.overtime_hours ?? '—'}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.custom_earnings_total ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.gross_pay)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.custom_deductions_total ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.total_deductions)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums font-semibold">{fmt(h.net_pay)}</td>
                      <td className="py-2 font-mono text-gray-500">{h.check_number ?? '—'}</td>
                    </tr>
                  ))}
                  {report.history.length === 0 && (
                    <tr>
                      <td colSpan={10} className="py-6 text-center text-gray-400">
                        No pay history found.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

// ─── YTD Summary Panel ────────────────────────────────────────────────────────

function YtdSummaryPanel() {
  const currentYear = new Date().getFullYear();
  const yearOptions = Array.from({ length: currentYear - 2020 + 1 }, (_, i) => currentYear - i);
  const [year, setYear] = useState(currentYear);
  const [periodMode, setPeriodMode] = useState<'year' | 'custom'>('year');
  const [startDate, setStartDate] = useState(`${currentYear}-01-01`);
  const [endDate, setEndDate] = useState(new Date().toISOString().slice(0, 10));
  const [search, setSearch] = useState('');
  const [employmentType, setEmploymentType] = useState('all');
  const [status, setStatus] = useState('all');
  const [sortBy, setSortBy] = useState<NonNullable<YtdSummaryParams['sort_by']>>('name');
  const [sortDirection, setSortDirection] = useState<NonNullable<YtdSummaryParams['sort_direction']>>('asc');
  const [loading, setLoading] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<YtdSummaryReport['report'] | null>(null);

  function reportParams(overrides: Partial<YtdSummaryParams> = {}): YtdSummaryParams {
    return {
      ...(periodMode === 'custom' ? { start_date: startDate, end_date: endDate } : { year }),
      sort_by: sortBy,
      sort_direction: sortDirection,
      ...(search.trim() ? { search: search.trim() } : {}),
      ...(employmentType !== 'all' ? { employment_type: employmentType } : {}),
      ...(status !== 'all' ? { status } : {}),
      ...overrides,
    };
  }

  function updateSort(field: NonNullable<YtdSummaryParams['sort_by']>) {
    const nextDirection =
      sortBy === field
        ? (sortDirection === 'asc' ? 'desc' : 'asc')
        : (field === 'name' || field === 'employment_type' || field === 'status' ? 'asc' : 'desc');

    if (sortBy === field) {
      setSortDirection(nextDirection);
    } else {
      setSortBy(field);
      setSortDirection(nextDirection);
    }

    if (report) {
      void loadReport({ sort_by: field, sort_direction: nextDirection });
    } else {
      setReport(null);
    }
  }

  function sortLabel(field: NonNullable<YtdSummaryParams['sort_by']>) {
    if (sortBy !== field) return '';
    return sortDirection === 'asc' ? ' ↑' : ' ↓';
  }

  async function loadReport(overrides: Partial<YtdSummaryParams> = {}) {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.ytdSummary(reportParams(overrides));
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.ytdSummaryXlsx(reportParams());
      triggerDownload(blob, filename || `payroll_summary_${periodMode === 'custom' ? `${startDate}_to_${endDate}` : year}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.ytdSummaryPdf(reportParams());
      triggerDownload(blob, filename || `payroll_summary_${periodMode === 'custom' ? `${startDate}_to_${endDate}` : year}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadCsv() {
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.ytdSummaryCsv(reportParams());
      triggerDownload(blob, filename || `payroll_summary_${periodMode === 'custom' ? `${startDate}_to_${endDate}` : year}.csv`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  const exportFormats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'PDF report (.pdf)', description: 'Review-ready payroll summary.', kind: 'pdf', loading: exportingPdf, onSelect: downloadPdf },
    { key: 'xlsx', label: 'Excel workbook (.xlsx)', description: 'Payroll detail and reconciliation sheets.', kind: 'spreadsheet', loading: exportingXlsx, onSelect: downloadXlsx },
    { key: 'csv', label: 'Payroll data (.csv)', description: 'Flat employee totals for analysis.', kind: 'data', loading: exportingCsv, onSelect: downloadCsv },
  ];

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Payroll Summary by Period</CardTitle>
          <CardDescription>
            Payroll totals and field-level reconciliation for any pay-date period.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <select aria-label="Payroll summary period type" value={periodMode} onChange={(e) => { setPeriodMode(e.target.value as 'year' | 'custom'); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm">
              <option value="year">Calendar year</option>
              <option value="custom">Custom pay dates</option>
            </select>
            {periodMode === 'custom' ? <>
              <input aria-label="Payroll summary start date" type="date" value={startDate} onChange={(e) => { setStartDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
              <span className="text-sm text-gray-500">to</span>
              <input aria-label="Payroll summary end date" type="date" value={endDate} onChange={(e) => { setEndDate(e.target.value); setReport(null); }} className="h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm" />
            </> : <>
            <div className="flex items-center gap-2">
              <label htmlFor="ytd-year" className="text-sm font-medium text-gray-700">Year</label>
              <select
                id="ytd-year"
                value={year}
                onChange={(e) => { setYear(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            </>}
            <div className="flex items-center gap-2">
              <label htmlFor="ytd-search" className="text-sm font-medium text-gray-700">Search</label>
              <input
                id="ytd-search"
                value={search}
                onChange={(e) => { setSearch(e.target.value); setReport(null); }}
                placeholder="Employee name"
                className="h-9 w-48 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              />
            </div>
            <div className="flex items-center gap-2">
              <label htmlFor="ytd-type" className="text-sm font-medium text-gray-700">Type</label>
              <select
                id="ytd-type"
                value={employmentType}
                onChange={(e) => { setEmploymentType(e.target.value); setReport(null); }}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              >
                <option value="all">All types</option>
                <option value="hourly">Hourly</option>
                <option value="salary">Salary</option>
                <option value="contractor">Contractor</option>
              </select>
            </div>
            <div className="flex items-center gap-2">
              <label htmlFor="ytd-status" className="text-sm font-medium text-gray-700">Status</label>
              <select
                id="ytd-status"
                value={status}
                onChange={(e) => { setStatus(e.target.value); setReport(null); }}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
              >
                <option value="all">All statuses</option>
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
                <option value="terminated">Terminated</option>
              </select>
            </div>
            <Button onClick={() => loadReport()} disabled={loading}>
              {loading ? 'Loading…' : 'View Report'}
            </Button>
            <ReportDownloadMenu formats={exportFormats} disabled={loading || exportingPdf || exportingXlsx || exportingCsv} />
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Payroll Summary — {report.period.label}</CardTitle>
              <CardDescription>
                Pay-date basis &bull; {report.employees.length} employee{report.employees.length !== 1 ? 's' : ''}
                {report.company_totals?.payroll_count != null && (
                  <> &bull; {report.company_totals.payroll_count} payroll{report.company_totals.payroll_count !== 1 ? 's' : ''}</>
                )}
              </CardDescription>
            </CardHeader>
            <CardContent>
              {report.company_totals && (
                <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 mb-6">
                  <TotalBox label="Total Gross Pay" value={report.company_totals.gross_pay} />
                  <TotalBox label="Other Earnings" value={report.company_totals.custom_earnings_total ?? 0} />
                  <TotalBox label="Payroll Field Additions" value={(report.company_totals.payroll_field_taxable_additions_total ?? 0) + (report.company_totals.payroll_field_non_taxable_additions_total ?? 0)} />
                  <TotalBox label="Total Withholding" value={report.company_totals.withholding_tax} />
                  <TotalBox label="Total SS Tax" value={report.company_totals.social_security_tax} />
                  <TotalBox label="Total Medicare" value={report.company_totals.medicare_tax} />
                  <TotalBox label="Total Retirement" value={report.company_totals.retirement} />
                  <TotalBox label="Other Deductions" value={report.company_totals.custom_deductions_total ?? 0} />
                  <TotalBox label="Payroll Field Deductions" value={(report.company_totals.payroll_field_pre_tax_deductions_total ?? 0) + (report.company_totals.payroll_field_post_tax_deductions_total ?? 0)} />
                  <TotalBox label="Employer Contributions" value={report.company_totals.payroll_field_employer_contributions_total ?? 0} />
                  <TotalBox label="Total Deductions" value={report.company_totals.total_deductions ?? 0} />
                  <TotalBox label="Total Net Pay" value={report.company_totals.net_pay} />
                </div>
              )}
              <PayrollFieldTotalsTable disclosure={report.payroll_fields} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Employee Detail</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-gray-500">
                    <SortableTh label="Employee" activeLabel={sortLabel('name')} onClick={() => updateSort('name')} />
                    <SortableTh label="Type" activeLabel={sortLabel('employment_type')} onClick={() => updateSort('employment_type')} />
                    <SortableTh label="Status" activeLabel={sortLabel('status')} onClick={() => updateSort('status')} />
                    <SortableTh label="Gross Pay" activeLabel={sortLabel('gross_pay')} align="right" onClick={() => updateSort('gross_pay')} />
                    <SortableTh label="Other Earn." activeLabel={sortLabel('custom_earnings_total')} align="right" onClick={() => updateSort('custom_earnings_total')} />
                    <th className="py-2 pr-4 text-right font-medium">Field Add.</th>
                    <SortableTh label="Withholding" activeLabel={sortLabel('withholding_tax')} align="right" onClick={() => updateSort('withholding_tax')} />
                    <SortableTh label="SS Tax" activeLabel={sortLabel('social_security_tax')} align="right" onClick={() => updateSort('social_security_tax')} />
                    <SortableTh label="Medicare" activeLabel={sortLabel('medicare_tax')} align="right" onClick={() => updateSort('medicare_tax')} />
                    <SortableTh label="Retirement" activeLabel={sortLabel('retirement')} align="right" onClick={() => updateSort('retirement')} />
                    <SortableTh label="Other Ded." activeLabel={sortLabel('custom_deductions_total')} align="right" onClick={() => updateSort('custom_deductions_total')} />
                    <th className="py-2 pr-4 text-right font-medium">Field Ded.</th>
                    <th className="py-2 pr-4 text-right font-medium">Employer Contrib.</th>
                    <SortableTh label="Total Ded." activeLabel={sortLabel('total_deductions')} align="right" onClick={() => updateSort('total_deductions')} />
                    <SortableTh label="Net Pay" activeLabel={sortLabel('net_pay')} align="right" onClick={() => updateSort('net_pay')} />
                  </tr>
                </thead>
                <tbody>
                  {report.employees.map((emp) => (
                    <tr key={emp.employee_id} className="border-b last:border-0 hover:bg-gray-50">
                      <td className="py-2 pr-4 font-medium">{emp.name}</td>
                      <td className="py-2 pr-4 capitalize text-gray-500">{emp.employment_type}</td>
                      <td className="py-2 pr-4">
                        <Badge variant={emp.status === 'active' ? 'success' : 'default'}>
                          {emp.status}
                        </Badge>
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.gross_pay)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.custom_earnings_total ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt((emp.payroll_field_taxable_additions_total ?? 0) + (emp.payroll_field_non_taxable_additions_total ?? 0))}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.withholding_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.social_security_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.medicare_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.retirement)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.custom_deductions_total ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt((emp.payroll_field_pre_tax_deductions_total ?? 0) + (emp.payroll_field_post_tax_deductions_total ?? 0))}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.payroll_field_employer_contributions_total ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.total_deductions ?? 0)}</td>
                      <td className="py-2 text-right tabular-nums font-semibold">{fmt(emp.net_pay)}</td>
                    </tr>
                  ))}
                  {report.employees.length === 0 && (
                    <tr>
                      <td colSpan={15} className="py-6 text-center text-gray-400">
                        No employee data found for {report.period.label}.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

// ─── Employer Tax Liability Panel ─────────────────────────────────────────────

function EmployerLiabilityPanel() {
  const currentYear = new Date().getFullYear();
  const yearOptions = Array.from({ length: currentYear - 2020 + 1 }, (_, i) => currentYear - i);
  const [year, setYear] = useState(currentYear);
  const [quarter, setQuarter] = useState<number | undefined>(undefined);
  const [loading, setLoading] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TaxSummaryReport['report'] | null>(null);

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.taxSummary({ year, quarter });
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryXlsx({ year, quarter });
      triggerDownload(blob, filename || `employer_liability_${year}${quarter ? `_q${quarter}` : ''}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryPdf({ year, quarter });
      triggerDownload(blob, filename || `employer_liability_${year}${quarter ? `_q${quarter}` : ''}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadCsv() {
    setExportingCsv(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.taxSummaryCsv({ year, quarter });
      triggerDownload(blob, filename || `employer_liability_${year}${quarter ? `_q${quarter}` : ''}.csv`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingCsv(false);
    }
  }

  const exportFormats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'PDF report (.pdf)', description: 'Printable employer liability review.', kind: 'pdf', loading: exportingPdf, onSelect: downloadPdf },
    { key: 'xlsx', label: 'Excel workbook (.xlsx)', description: 'Detailed reconciliation workbook.', kind: 'spreadsheet', loading: exportingXlsx, onSelect: downloadXlsx },
    { key: 'csv', label: 'Liability data (.csv)', description: 'Flat liability totals for analysis.', kind: 'data', loading: exportingCsv, onSelect: downloadCsv },
  ];

  const periodLabel = quarter ? `Q${quarter} ${year}` : `${year} Full Year`;

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Employer Tax Liability</CardTitle>
          <CardDescription>
            Employer-side payroll tax obligations — Social Security match (6.2%) and Medicare match (1.45%).
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="el-year" className="text-sm font-medium text-gray-700">Year</label>
              <select
                id="el-year"
                value={year}
                onChange={(e) => { setYear(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            <div className="flex items-center gap-2">
              <label htmlFor="el-quarter" className="text-sm font-medium text-gray-700">Quarter</label>
              <select
                id="el-quarter"
                value={quarter ?? ''}
                onChange={(e) => { setQuarter(e.target.value ? Number(e.target.value) : undefined); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                <option value="">Full Year</option>
                <option value="1">Q1 (Jan–Mar)</option>
                <option value="2">Q2 (Apr–Jun)</option>
                <option value="3">Q3 (Jul–Sep)</option>
                <option value="4">Q4 (Oct–Dec)</option>
              </select>
            </div>
            <Button onClick={loadReport} disabled={loading}>
              {loading ? 'Loading…' : 'View Report'}
            </Button>
            <ReportDownloadMenu formats={exportFormats} disabled={loading || exportingPdf || exportingXlsx || exportingCsv} />
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <Card>
          <CardHeader>
            <CardTitle>Employer Tax Liability — {periodLabel}</CardTitle>
            <CardDescription>
              {report.pay_periods_included} pay period{report.pay_periods_included !== 1 ? 's' : ''} &bull;{' '}
              {report.employee_count} employee{report.employee_count !== 1 ? 's' : ''}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-2 md:grid-cols-3 gap-4 mb-6">
              <TotalBox label="Gross Wages" value={report.totals.gross_wages} />
              <div className="rounded-md border border-blue-200 bg-blue-50 p-3">
                <p className="text-xs text-blue-700">Employer SS (6.2%)</p>
                <p className="mt-1 text-lg font-semibold tabular-nums">{fmt(report.totals.social_security_employer)}</p>
              </div>
              <div className="rounded-md border border-blue-200 bg-blue-50 p-3">
                <p className="text-xs text-blue-700">Employer Medicare (1.45%)</p>
                <p className="mt-1 text-lg font-semibold tabular-nums">{fmt(report.totals.medicare_employer)}</p>
              </div>
            </div>
            <div className="rounded-md border border-blue-300 bg-blue-100 p-4">
              <div className="flex justify-between items-center">
                <p className="text-sm font-medium text-blue-900">Total Employer Tax Liability</p>
                <p className="text-xl font-bold tabular-nums text-blue-900">
                  {fmt(report.totals.social_security_employer + report.totals.medicare_employer)}
                </p>
              </div>
              <p className="text-xs text-blue-700 mt-1">
                Employer SS ({fmt(report.totals.social_security_employer)}) + Employer Medicare ({fmt(report.totals.medicare_employer)})
              </p>
            </div>

            <div className="mt-6 rounded-md bg-gray-50 border p-4">
              <h4 className="text-sm font-medium text-gray-700 mb-3">Full Tax Breakdown</h4>
              <div className="grid grid-cols-2 gap-3 text-sm">
                <div className="flex justify-between">
                  <span className="text-gray-600">Employee Withholding (FIT)</span>
                  <span className="tabular-nums">{fmt(report.totals.withholding_tax)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Employee SS</span>
                  <span className="tabular-nums">{fmt(report.totals.social_security_employee)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Employer SS</span>
                  <span className="tabular-nums font-medium">{fmt(report.totals.social_security_employer)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Employee Medicare</span>
                  <span className="tabular-nums">{fmt(report.totals.medicare_employee)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Employer Medicare</span>
                  <span className="tabular-nums font-medium">{fmt(report.totals.medicare_employer)}</span>
                </div>
                <div className="flex justify-between border-t pt-2 col-span-2">
                  <span className="text-gray-700 font-medium">Total Employment Taxes</span>
                  <span className="tabular-nums font-semibold">{fmt(report.totals.total_employment_taxes)}</span>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

// ─── Quarterly Compliance Packet Panel ───────────────────────────────────────

function QuarterlyCompliancePacketPanel() {
  const currentYear = new Date().getFullYear();
  const yearOptions = Array.from({ length: currentYear - 2020 + 1 }, (_, i) => currentYear - i);
  const currentQuarter = Math.ceil((new Date().getMonth() + 1) / 3);
  const [year, setYear] = useState(currentYear);
  const [quarter, setQuarter] = useState(currentQuarter);
  const [loading, setLoading] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [exportingSwica, setExportingSwica] = useState(false);
  const [savingTaskId, setSavingTaskId] = useState<number | null>(null);
  const [reviewFormType, setReviewFormType] = useState<QuarterlyOfficialFormType | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<QuarterlyCompliancePacketReport | null>(null);

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.quarterlyCompliancePacket(year, quarter);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.quarterlyCompliancePacketXlsx(year, quarter);
      triggerDownload(blob, filename || `quarterly_compliance_packet_${year}_q${quarter}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.quarterlyCompliancePacketPdf(year, quarter);
      triggerDownload(blob, filename || `quarterly_compliance_packet_${year}_q${quarter}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  async function downloadSwicaAscii() {
    setExportingSwica(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.quarterlyCompliancePacketSwicaAscii(year, quarter);
      triggerDownload(blob, filename || `swica_${year}_q${quarter}.txt`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingSwica(false);
    }
  }

  async function updateTask(task: QuarterlyComplianceTask, updates: Partial<QuarterlyComplianceTask>) {
    setSavingTaskId(task.id);
    setError(null);
    try {
      const res = await reportsApi.updateQuarterlyComplianceTask(task.id, updates);
      setReport((current) => {
        if (!current?.workflow) return current;
        return {
          ...current,
          workflow: {
            ...current.workflow,
            tasks: current.workflow.tasks.map((existing) => existing.id === task.id ? res.task : existing),
          },
        };
      });
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setSavingTaskId(null);
    }
  }

  const reviewNeedsAttention = report?.review_checks.filter((check) => check.status !== 'ok').length ?? 0;
  const exportFormats: ReportDownloadFormat[] = [
    {
      key: 'pdf',
      label: 'Combined compliance packet (.pdf)',
      description: 'Summary and official filing forms in one review-ready PDF.',
      kind: 'pdf',
      loading: exportingPdf,
      onSelect: downloadPdf,
    },
    {
      key: 'xlsx',
      label: 'Reconciliation workbook (.xlsx)',
      description: 'Detailed source schedules and tie-outs for accountants.',
      kind: 'spreadsheet',
      loading: exportingXlsx,
      onSelect: downloadXlsx,
    },
    {
      key: 'swica',
      label: 'SWICA upload file (.txt)',
      description: 'Fixed-width filing upload; available when validation passes.',
      kind: 'filing',
      loading: exportingSwica,
      onSelect: downloadSwicaAscii,
    },
  ];

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Quarterly Compliance Packet</CardTitle>
          <CardDescription>
            Pay-date based Guam and federal filing packet for Form 500, W-1, SWICA, Federal Form 941, and tie-out review.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="qcp-year" className="text-sm font-medium text-gray-700">Year</label>
              <select
                id="qcp-year"
                value={year}
                onChange={(e) => { setYear(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => <option key={y} value={y}>{y}</option>)}
              </select>
            </div>
            <div className="flex items-center gap-2">
              <label htmlFor="qcp-quarter" className="text-sm font-medium text-gray-700">Quarter</label>
              <select
                id="qcp-quarter"
                value={quarter}
                onChange={(e) => { setQuarter(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                <option value="1">Q1 (Jan-Mar)</option>
                <option value="2">Q2 (Apr-Jun)</option>
                <option value="3">Q3 (Jul-Sep)</option>
                <option value="4">Q4 (Oct-Dec)</option>
              </select>
            </div>
            <Button onClick={loadReport} disabled={loading}>
              {loading ? 'Loading...' : 'View Packet'}
            </Button>
            <ReportDownloadMenu formats={exportFormats} disabled={loading || exportingPdf || exportingXlsx || exportingSwica} />
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>{report.meta.company_name} - {report.meta.quarter_label}</CardTitle>
              <CardDescription>
                Pay-date basis: {report.meta.quarter_start} to {report.meta.quarter_end} | Official due {report.due_dates.official_due_date} | Internal target {report.due_dates.internal_target_date}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid gap-4 md:grid-cols-4">
                <div className="rounded-md border p-4">
                  <p className="text-sm text-gray-500">Form 500 / W-1</p>
                  <p className="mt-1 text-xl font-semibold">{fmt(report.w1.total_guam_withholding)}</p>
                </div>
                <div className="rounded-md border p-4">
                  <p className="text-sm text-gray-500">SWICA Wages</p>
                  <p className="mt-1 text-xl font-semibold">{fmt(report.swica.totals.total_wages)}</p>
                </div>
                <div className="rounded-md border p-4">
                  <p className="text-sm text-gray-500">SWICA Employees</p>
                  <p className="mt-1 text-xl font-semibold">{report.swica.totals.employee_count}</p>
                </div>
                <div className="rounded-md border p-4">
                  <p className="text-sm text-gray-500">Review Checks</p>
                  <p className="mt-1 text-xl font-semibold">{reviewNeedsAttention === 0 ? 'Ready' : `${reviewNeedsAttention} review`}</p>
                </div>
              </div>
            </CardContent>
          </Card>

          {report.workflow && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Quarterly Filing Workflow</CardTitle>
                <CardDescription>
                  Track filing/payment status, confirmations, proof, and review readiness for this company and quarter.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <div className="grid gap-3 lg:grid-cols-2">
                  {report.workflow.tasks.map((task) => (
                    <div key={task.id} className="rounded-2xl border border-neutral-200 bg-white p-4">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-neutral-950">{task.title}</p>
                          <p className="mt-1 text-xs text-neutral-500">
                            Due {task.due_date || report.due_dates.official_due_date} · Target {task.internal_target_date || report.due_dates.internal_target_date}
                          </p>
                        </div>
                        <Badge variant={task.status.includes('filed') || task.status === 'paid' ? 'success' : task.status === 'needs_review' || task.status === 'exception' ? 'warning' : 'outline'}>
                          {task.status.replaceAll('_', ' ')}
                        </Badge>
                      </div>
                      <div className="mt-4 grid gap-3 sm:grid-cols-2">
                        <label className="text-xs font-semibold text-neutral-500">
                          Status
                          <select
                            value={task.status}
                            disabled={savingTaskId === task.id}
                            onChange={(e) => updateTask(task, { status: e.target.value })}
                            className="mt-1 h-9 w-full rounded-md border border-neutral-200 bg-white px-3 text-sm text-neutral-900"
                          >
                            {['not_started', 'in_progress', 'needs_review', 'ready_to_file', 'filed', 'paid', 'filed_and_paid', 'not_required', 'exception'].map((status) => (
                              <option key={status} value={status}>{status.replaceAll('_', ' ')}</option>
                            ))}
                          </select>
                        </label>
                        <label className="text-xs font-semibold text-neutral-500">
                          Confirmation #
                          <input
                            defaultValue={task.filing_confirmation_number || ''}
                            disabled={savingTaskId === task.id}
                            onBlur={(e) => updateTask(task, { filing_confirmation_number: e.target.value })}
                            className="mt-1 h-9 w-full rounded-md border border-neutral-200 bg-white px-3 text-sm text-neutral-900"
                          />
                        </label>
                      </div>
                    </div>
                  ))}
                </div>
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Official Forms</CardTitle>
              <CardDescription>
                Review editable values first, then preview the official PDF before printing or downloading. Guam W-1 and SWICA still need to be filed in GuamTax.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="flex flex-wrap gap-3">
                <Button
                  variant="outline"
                  onClick={() => setReviewFormType('form_941')}
                >
                  Review 941
                </Button>
                <Button
                  variant="outline"
                  onClick={() => setReviewFormType('schedule_b')}
                >
                  Review Schedule B
                </Button>
                <Button
                  variant="outline"
                  onClick={() => setReviewFormType('w1')}
                >
                  Review W-1
                </Button>
                <Button
                  variant="outline"
                  onClick={() => setReviewFormType('swica')}
                >
                  Review SW-2
                </Button>
                <Button
                  variant="outline"
                  onClick={downloadSwicaAscii}
                  disabled={exportingSwica || !report.swica.upload_export_ready}
                  title={report.swica.upload_export_note}
                >
                  {exportingSwica ? 'Exporting...' : 'Download SWICA Upload'}
                </Button>
              </div>
              {!report.swica.upload_export_ready && (
                <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
                  <p className="font-semibold">SWICA upload is not ready yet.</p>
                  <p className="mt-1">{report.swica.upload_export_note}</p>
                  {report.swica.upload_validation_errors?.length ? (
                    <ul className="mt-2 list-disc space-y-1 pl-5">
                      {report.swica.upload_validation_errors.slice(0, 5).map((issue) => <li key={issue}>{issue}</li>)}
                    </ul>
                  ) : null}
                </div>
              )}
            </CardContent>
          </Card>

          <div className="grid gap-6 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">W-1 Liability By Month</CardTitle>
                <CardDescription>Enter liabilities in GuamTax by actual pay date and reconcile to Form 500 deposits.</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Month</TableHead>
                      <TableHead className="text-right">Amount</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {report.w1.monthly_liabilities.map((row) => (
                      <TableRow key={row.month_number}>
                        <TableCell>{row.month}</TableCell>
                        <TableCell className="text-right tabular-nums">{fmt(row.amount)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">Federal Form 941</CardTitle>
                <CardDescription>{report.federal_941.deposit_schedule.note}</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="space-y-3 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-600">Suggested deposit schedule</span>
                    <span className="font-medium capitalize">{report.federal_941.deposit_schedule.suggested_schedule}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-600">Schedule B required</span>
                    <span className="font-medium">{report.federal_941.deposit_schedule.schedule_b_required ? 'Yes' : 'No'}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-600">Line 5e SS/Medicare</span>
                    <span className="font-medium tabular-nums">{fmt(report.federal_941.report.lines.line5e_total_ss_medicare)}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-600">Lines 2 and 3</span>
                    <span className="font-medium">Skipped for Guam</span>
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Review Checks</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="space-y-2">
                {report.review_checks.map((check) => (
                  <div key={check.key} className="rounded-md border px-3 py-2">
                    <div className="flex items-start justify-between gap-4">
                      <div>
                        <p className="text-sm text-gray-700">{check.message}</p>
                        {check.details ? (
                          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500">
                            {Object.entries(check.details).map(([key, value]) => (
                              <span key={key}>{key.replaceAll('_', ' ')}: <span className="font-medium text-gray-700">{String(value ?? 'blank')}</span></span>
                            ))}
                          </div>
                        ) : null}
                        {check.href ? <Link to={check.href} className="mt-2 inline-block text-xs font-medium text-primary-700">Open source records</Link> : null}
                      </div>
                      <Badge variant={check.status === 'ok' ? 'success' : 'warning'}>{check.status}</Badge>
                    </div>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Employee Reconciliation</CardTitle>
              <CardDescription>Per-employee totals for SWICA, W-1, and Federal Form 941 tie-out review.</CardDescription>
            </CardHeader>
            <CardContent>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead className="text-right">Gross</TableHead>
                    <TableHead className="text-right">Net</TableHead>
                    <TableHead className="text-right">Deductions</TableHead>
                    <TableHead className="text-right">Guam W/H</TableHead>
                    <TableHead className="text-right">SS</TableHead>
                    <TableHead className="text-right">Medicare</TableHead>
                    <TableHead className="text-right">941 Liability</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {report.swica.employees.map((employee) => (
                    <TableRow key={employee.employee_id}>
                      <TableCell>{employee.name}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.gross_pay)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.net_pay)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.deductions)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.guam_withholding)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.social_security_tax + employee.employer_social_security_tax)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.medicare_tax + employee.employer_medicare_tax)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmt(employee.federal_941_liability)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </>
      )}
      {reviewFormType && (
        <QuarterlyOfficialFormModal
          year={year}
          quarter={quarter}
          formType={reviewFormType}
          onClose={() => setReviewFormType(null)}
        />
      )}
    </div>
  );
}

function QuarterlyOfficialFormModal({
  year,
  quarter,
  formType,
  onClose,
}: {
  year: number;
  quarter: number;
  formType: QuarterlyOfficialFormType;
  onClose: () => void;
}) {
  const [fields, setFields] = useState<QuarterlyOfficialFormFields | null>(null);
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewBlob, setPreviewBlob] = useState<Blob | null>(null);
  const [previewFilename, setPreviewFilename] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    setPreviewUrl(null);
    setPreviewBlob(null);
    void reportsApi.quarterlyCompliancePacketOfficialFormDefaults(year, quarter, formType)
      .then((res) => {
        if (active) setFields(res.data);
      })
      .catch((err) => {
        if (active) setError(extractErrorMessage(err));
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [formType, quarter, year]);

  useEffect(() => {
    return () => {
      if (previewUrl) URL.revokeObjectURL(previewUrl);
    };
  }, [previewUrl]);

  function updateField(key: keyof QuarterlyOfficialFormFields, value: string) {
    setFields((prev) => (prev ? { ...prev, [key]: value } : prev));
  }

  function updateLine(key: string, value: string) {
    setFields((prev) => (prev ? { ...prev, lines: { ...(prev.lines || {}), [key]: value } } : prev));
  }

  function updateDaily(index: number, value: string) {
    setFields((prev) => {
      if (!prev?.daily_liabilities) return prev;
      const daily = [...prev.daily_liabilities];
      daily[index] = { ...daily[index], amount: Number(value) };
      return { ...prev, daily_liabilities: daily };
    });
  }

  function updateEmployee(index: number, key: string, value: string) {
    setFields((prev) => {
      if (!prev?.employees) return prev;
      const employees = [...prev.employees];
      employees[index] = { ...employees[index], [key]: key === 'name' ? value : Number(value) };
      return { ...prev, employees };
    });
  }

  async function previewPdf() {
    if (!fields) return;
    setWorking(true);
    setError(null);
    try {
      const file = await reportsApi.quarterlyCompliancePacketOfficialFormPreview(year, quarter, formType, fields);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      const url = URL.createObjectURL(file.blob);
      setPreviewUrl(url);
      setPreviewBlob(file.blob);
      setPreviewFilename(file.filename || `${formType}_${year}_q${quarter}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setWorking(false);
    }
  }

  async function downloadPdf() {
    if (!fields) return;
    setWorking(true);
    setError(null);
    try {
      const file = await reportsApi.quarterlyCompliancePacketOfficialFormDownload(year, quarter, formType, fields);
      triggerDownload(file.blob, file.filename || `${formType}_${year}_q${quarter}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setWorking(false);
    }
  }

  function downloadPreview() {
    if (!previewBlob) return;
    triggerDownload(previewBlob, previewFilename || `${formType}_${year}_q${quarter}.pdf`);
  }

  function printPreview() {
    if (!previewUrl) return;
    const printWindow = window.open(previewUrl, '_blank');
    printWindow?.addEventListener('load', () => printWindow.print());
  }

  return createPortal(
    <>
      <div className="fixed inset-0 z-[60] bg-black/55" onClick={onClose} />
      <div className="fixed inset-0 z-[61] flex items-center justify-center p-3 xl:p-5">
        <div className="flex h-[94vh] max-h-[94vh] w-[min(1600px,calc(100vw-1.5rem))] flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
          <div className="flex flex-col gap-3 border-b px-4 py-4 sm:flex-row sm:items-start sm:justify-between sm:px-6">
            <div>
              <h2 className="text-2xl font-semibold text-gray-900">{fields?.title || 'Official Form'}</h2>
              <p className="mt-1 text-sm text-gray-500">Review and adjust the filing values, then preview the official PDF before downloading or printing.</p>
            </div>
            <Button variant="outline" onClick={onClose}>Close</Button>
          </div>

          <div className="grid min-h-0 flex-1 gap-0 overflow-hidden lg:grid-cols-[minmax(400px,0.48fr)_1.52fr]">
            <div className="overflow-y-auto bg-gray-50 p-5">
              {error ? <div className="mb-4 rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{error}</div> : null}
              {loading || !fields ? (
                <div className="rounded-md border bg-white p-4 text-sm text-gray-500 sm:p-6">Loading form values...</div>
              ) : (
                <div className="space-y-5">
                  <section className="rounded-md border bg-white p-4">
                    <div className="grid gap-3 md:grid-cols-2">
                      <Field label="Company Name">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_name || ''} onChange={(e) => updateField('company_name', e.target.value)} />
                      </Field>
                      <Field label="EIN">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.ein || ''} onChange={(e) => updateField('ein', e.target.value)} />
                      </Field>
                      <Field label="Address Line 1">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_address_line1 || fields.company_address || ''} onChange={(e) => updateField('company_address_line1', e.target.value)} />
                      </Field>
                      <Field label="Address Line 2">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_address_line2 || ''} onChange={(e) => updateField('company_address_line2', e.target.value)} />
                      </Field>
                      <Field label="City">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_city || ''} onChange={(e) => updateField('company_city', e.target.value)} />
                      </Field>
                      <Field label="State">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_state || ''} onChange={(e) => updateField('company_state', e.target.value)} />
                      </Field>
                      <Field label="ZIP">
                        <input className="h-9 w-full rounded-md border px-3 text-sm" value={fields.company_zip || ''} onChange={(e) => updateField('company_zip', e.target.value)} />
                      </Field>
                    </div>
                  </section>

                  {fields.lines ? (
                    <section className="rounded-md border bg-white p-4">
                      <h3 className="text-sm font-semibold text-gray-900">941 Lines</h3>
                      <div className="mt-3 grid gap-3 md:grid-cols-2">
                        {Object.entries(fields.lines).filter(([, value]) => value !== null).map(([key, value]) => (
                          <Field key={key} label={key.replaceAll('_', ' ')}>
                            <input className="h-9 w-full rounded-md border px-3 text-sm" value={String(value ?? '')} onChange={(e) => updateLine(key, e.target.value)} />
                          </Field>
                        ))}
                      </div>
                    </section>
                  ) : null}

                  {fields.daily_liabilities ? (
                    <section className="rounded-md border bg-white p-4">
                      <h3 className="text-sm font-semibold text-gray-900">Pay-Date Liabilities</h3>
                      <div className="mt-3 space-y-2">
                        {fields.daily_liabilities.map((row, index) => (
                          <div key={`${row.pay_date}-${index}`} className="grid grid-cols-[1fr_140px] gap-3">
                            <input className="h-9 rounded-md border px-3 text-sm" value={row.pay_date} readOnly />
                            <input className="h-9 rounded-md border px-3 text-sm text-right" value={row.amount} onChange={(e) => updateDaily(index, e.target.value)} />
                          </div>
                        ))}
                      </div>
                    </section>
                  ) : null}

                  {fields.employees ? (
                    <section className="rounded-md border bg-white p-4">
                      <h3 className="text-sm font-semibold text-gray-900">SWICA Employees</h3>
                      <div className="mt-3 space-y-3">
                        {fields.employees.map((employee, index) => (
                          <div key={`${employee.employee_id}-${index}`} className="grid gap-2 rounded-md border p-3 md:grid-cols-3">
                            <input className="h-9 rounded-md border px-3 text-sm md:col-span-3" value={String(employee.name || '')} onChange={(e) => updateEmployee(index, 'name', e.target.value)} />
                            <input className="h-9 rounded-md border px-3 text-sm text-right" value={String(employee.swica_wages || 0)} onChange={(e) => updateEmployee(index, 'swica_wages', e.target.value)} />
                            <input className="h-9 rounded-md border px-3 text-sm text-right" value={String(employee.guam_withholding || 0)} onChange={(e) => updateEmployee(index, 'guam_withholding', e.target.value)} />
                            <input className="h-9 rounded-md border px-3 text-sm text-right" value={String(employee.reported_tips || 0)} onChange={(e) => updateEmployee(index, 'reported_tips', e.target.value)} />
                          </div>
                        ))}
                      </div>
                    </section>
                  ) : null}
                </div>
              )}
            </div>

            <div className="flex min-h-0 flex-col border-l">
              <div className="flex flex-wrap items-center justify-end gap-3 border-b bg-white px-4 py-3">
                <Button variant="outline" onClick={previewPdf} disabled={working || !fields}>Preview PDF</Button>
                <Button variant="outline" onClick={downloadPdf} disabled={working || !fields}>Download PDF</Button>
                <Button variant="outline" onClick={printPreview} disabled={!previewUrl}>Print</Button>
                <Button variant="outline" onClick={downloadPreview} disabled={!previewBlob}>Download Preview</Button>
              </div>
              <div className="min-h-0 flex-1 bg-gray-200">
                {previewUrl ? (
                  <iframe src={previewUrl} title={fields?.title || 'Official form preview'} className="h-full w-full border-0 bg-white" />
                ) : (
                  <div className="flex h-full items-center justify-center text-sm text-gray-500">Preview the PDF after reviewing the values.</div>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </>,
    document.body
  );
}

// ─── Federal Form 941 Panel ──────────────────────────────────────────────────

function Form941GuPanel() {
  const currentYear = new Date().getFullYear();
  const yearOptions = Array.from({ length: currentYear - 2020 + 1 }, (_, i) => currentYear - i);
  const currentQuarter = Math.ceil((new Date().getMonth() + 1) / 3);
  const [year, setYear] = useState(currentYear);
  const [quarter, setQuarter] = useState(currentQuarter);
  const [loading, setLoading] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<Form941GuReport | null>(null);

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.form941Gu(year, quarter);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  async function downloadXlsx() {
    setExportingXlsx(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.form941GuXlsx(year, quarter);
      triggerDownload(blob, filename || `federal_form_941_${year}_q${quarter}.xlsx`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingXlsx(false);
    }
  }

  async function downloadPdf() {
    setExportingPdf(true);
    setError(null);
    try {
      const { blob, filename } = await reportsApi.form941GuPdf(year, quarter);
      triggerDownload(blob, filename || `federal_form_941_${year}_q${quarter}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  const exportFormats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'Official Form 941 (.pdf)', description: 'Filled official federal form for review and filing.', kind: 'filing', loading: exportingPdf, onSelect: downloadPdf },
    { key: 'xlsx', label: '941 worksheet (.xlsx)', description: 'Supporting calculations and liability schedules.', kind: 'spreadsheet', loading: exportingXlsx, onSelect: downloadXlsx },
  ];

  const fmtOrPlaceholder = (v: number | null) => v != null ? fmt(v) : '—';

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Federal Form 941 Worksheet</CardTitle>
          <CardDescription>
            Federal Form 941 worksheet for Guam employers. Lines 2 and 3 are skipped unless employees are subject to U.S. income tax withholding.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap sm:items-center sm:gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="f941-year" className="text-sm font-medium text-gray-700">Year</label>
              <select
                id="f941-year"
                value={year}
                onChange={(e) => { setYear(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                {yearOptions.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            <div className="flex items-center gap-2">
              <label htmlFor="f941-quarter" className="text-sm font-medium text-gray-700">Quarter</label>
              <select
                id="f941-quarter"
                value={quarter}
                onChange={(e) => { setQuarter(Number(e.target.value)); setReport(null); setError(null); }}
                disabled={loading}
                className="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:opacity-60"
              >
                <option value="1">Q1 (Jan–Mar)</option>
                <option value="2">Q2 (Apr–Jun)</option>
                <option value="3">Q3 (Jul–Sep)</option>
                <option value="4">Q4 (Oct–Dec)</option>
              </select>
            </div>
            <Button onClick={loadReport} disabled={loading}>
              {loading ? 'Loading…' : 'View Worksheet'}
            </Button>
            <ReportDownloadMenu formats={exportFormats} disabled={loading || exportingPdf || exportingXlsx} />
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Federal Form 941 — {report.meta.quarter_label}</CardTitle>
              <CardDescription>
                {report.employer_info.name} &bull; EIN: {report.employer_info.ein || '—'} &bull;{' '}
                {report.meta.pay_periods_included} pay period{report.meta.pay_periods_included !== 1 ? 's' : ''} &bull;{' '}
                {report.meta.quarter_start} to {report.meta.quarter_end}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="space-y-4">
                <div className="rounded-md border overflow-hidden">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="bg-gray-50 border-b">
                        <th className="text-left px-4 py-2 font-medium text-gray-600">Line</th>
                        <th className="text-left px-4 py-2 font-medium text-gray-600">Description</th>
                        <th className="text-right px-4 py-2 font-medium text-gray-600">Taxable Amount</th>
                        <th className="text-right px-4 py-2 font-medium text-gray-600">Tax</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">1</td>
                        <td className="px-4 py-2">Number of employees</td>
                        <td className="px-4 py-2 text-right tabular-nums">{report.lines.line1_employee_count}</td>
                        <td className="px-4 py-2 text-right"></td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">2</td>
                        <td className="px-4 py-2">Wages, tips, and other compensation (skipped for Guam)</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmtOrPlaceholder(report.lines.line2_wages_tips_other)}</td>
                        <td className="px-4 py-2 text-right"></td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">3</td>
                        <td className="px-4 py-2">Federal income tax withheld (skipped for Guam)</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmtOrPlaceholder(report.lines.line3_fit_withheld)}</td>
                      </tr>
                      <tr className="border-b bg-gray-50">
                        <td className="px-4 py-2 font-mono text-gray-500">5a</td>
                        <td className="px-4 py-2">Taxable Social Security wages</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5a_ss_wages)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5a_ss_combined_tax)}</td>
                      </tr>
                      <tr className="border-b bg-gray-50">
                        <td className="px-4 py-2 font-mono text-gray-500">5b</td>
                        <td className="px-4 py-2">Taxable Social Security tips</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5b_ss_tips)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5b_ss_tips_combined_tax)}</td>
                      </tr>
                      <tr className="border-b bg-gray-50">
                        <td className="px-4 py-2 font-mono text-gray-500">5c</td>
                        <td className="px-4 py-2">Taxable Medicare wages & tips</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5c_medicare_wages)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5c_medicare_combined_tax)}</td>
                      </tr>
                      <tr className="border-b bg-gray-50">
                        <td className="px-4 py-2 font-mono text-gray-500">5d</td>
                        <td className="px-4 py-2">Taxable wages & tips subject to Additional Medicare Tax</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5d_add_medicare_wages)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5d_add_medicare_tax)}</td>
                      </tr>
                      <tr className="border-b font-medium">
                        <td className="px-4 py-2 font-mono text-gray-500">5e</td>
                        <td className="px-4 py-2">Total Social Security and Medicare taxes</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line5e_total_ss_medicare)}</td>
                      </tr>
                      <tr className="border-b font-medium bg-blue-50">
                        <td className="px-4 py-2 font-mono text-gray-500">6</td>
                        <td className="px-4 py-2">Total taxes before adjustments (line 5e for Guam)</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line6_total_taxes_before_adj)}</td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">7</td>
                        <td className="px-4 py-2">Adjustment: fractions of cents</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmtOrPlaceholder(report.lines.line7_adj_fractions_cents)}</td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">8</td>
                        <td className="px-4 py-2">Adjustment: sick pay</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums text-gray-400">{fmtOrPlaceholder(report.lines.line8_adj_sick_pay)}</td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">9</td>
                        <td className="px-4 py-2">Adjustment: tips and group-term life</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums text-gray-400">{fmtOrPlaceholder(report.lines.line9_adj_tips_group_life)}</td>
                      </tr>
                      <tr className="border-b font-medium bg-blue-50">
                        <td className="px-4 py-2 font-mono text-gray-500">10</td>
                        <td className="px-4 py-2">Total taxes after adjustments</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line10_total_taxes_after_adj)}</td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">11</td>
                        <td className="px-4 py-2">Nonrefundable portion of credit</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums text-gray-400">{fmtOrPlaceholder(report.lines.line11_nonrefundable_credits)}</td>
                      </tr>
                      <tr className="border-b font-medium">
                        <td className="px-4 py-2 font-mono text-gray-500">12</td>
                        <td className="px-4 py-2">Total taxes after adjustments and credits</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line12_total_after_credits)}</td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">13</td>
                        <td className="px-4 py-2">Total deposits for this quarter</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums text-gray-400">{fmtOrPlaceholder(report.lines.line13_total_deposits)}</td>
                      </tr>
                      <tr className="bg-amber-50">
                        <td className="px-4 py-2 font-mono text-gray-500">14</td>
                        <td className="px-4 py-2 font-medium">Balance due / overpayment</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums text-gray-400">{fmtOrPlaceholder(report.lines.line14_balance_due_or_overpayment)}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                {/* Monthly Liability Breakdown */}
                {report.monthly_liability && report.monthly_liability.length > 0 && (
                  <div className="mt-4">
                    <h4 className="text-sm font-medium text-gray-700 mb-2">Monthly Tax Liability (Schedule B)</h4>
                    <div className="rounded-md border overflow-hidden">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="bg-gray-50 border-b">
                            <th className="text-left px-4 py-2 font-medium text-gray-600">Month</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Guam W-1 Withholding</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">SS Combined</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Medicare Combined</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Addtl Medicare</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Total Liability</th>
                          </tr>
                        </thead>
                        <tbody>
                          {report.monthly_liability.map((m) => (
                            <tr key={m.month} className="border-b last:border-0">
                              <td className="px-4 py-2">{m.month}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.guam_withholding_for_w1 ?? 0)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.ss_combined + m.ss_tips_combined)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.medicare_combined)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.add_medicare_tax)}</td>
                              <td className="px-4 py-2 text-right tabular-nums font-semibold">{fmt(m.total_liability)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                )}

                {/* Tax Detail Breakdown */}
                <div className="mt-4 rounded-md bg-gray-50 border p-4">
                  <h4 className="text-sm font-medium text-gray-700 mb-3">Employee/Employer Tax Split</h4>
                  <div className="grid grid-cols-2 gap-3 text-sm">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee SS Tax</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.ss_employee)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer SS Tax</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.ss_employer)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee Medicare</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.medicare_employee)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Medicare</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.medicare_employer)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Additional Medicare (Employee)</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.additional_medicare_employee)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Reported Tips</span>
                      <span className="tabular-nums">{fmt(report.tax_detail.reported_tips)}</span>
                    </div>
                    <div className="flex justify-between border-t pt-2">
                      <span className="text-gray-700 font-medium">Total Employee Taxes</span>
                      <span className="tabular-nums font-semibold">{fmt(report.tax_detail.total_employee_taxes)}</span>
                    </div>
                    <div className="flex justify-between border-t pt-2">
                      <span className="text-gray-700 font-medium">Total Employer Taxes</span>
                      <span className="tabular-nums font-semibold">{fmt(report.tax_detail.total_employer_taxes)}</span>
                    </div>
                  </div>
                </div>

                {/* Caveats */}
                <div className="rounded-md bg-amber-50 border border-amber-200 p-3 space-y-1">
                  <p className="text-sm font-medium text-amber-800">Notes & Caveats</p>
                  {report.meta.caveats.map((c, i) => (
                    <p key={i} className="text-xs text-amber-700">• {c}</p>
                  ))}
                </div>
              </div>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

function TotalBox({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-md border p-3">
      <p className="text-xs text-gray-500 leading-tight">{label}</p>
      <p className="mt-1 text-lg font-semibold tabular-nums">{fmt(value)}</p>
    </div>
  );
}

function PayrollFieldTotalsTable({ disclosure }: { disclosure?: PayrollFieldsDisclosure }) {
  const rows = disclosure?.totals ?? [];
  if (rows.length === 0) return null;

  return (
    <div className="mt-6 overflow-hidden rounded-xl border border-gray-200">
      <div className="border-b border-gray-200 bg-gray-50 px-4 py-3">
        <h3 className="font-semibold text-gray-900">Payroll field reconciliation</h3>
        <p className="text-sm text-gray-500">Historical field values saved on the payrolls in this period.</p>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="border-b text-left text-xs uppercase tracking-wide text-gray-500"><th className="px-4 py-2">Field</th><th className="px-4 py-2">Treatment</th><th className="px-4 py-2">Paid by</th><th className="px-4 py-2 text-right">Amount</th></tr></thead>
          <tbody>{rows.map((row, index) => <tr key={`${row.label}-${row.tax_treatment}-${index}`} className="border-b last:border-0"><td className="px-4 py-2 font-medium">{row.label}</td><td className="px-4 py-2 text-gray-600">{row.tax_treatment.replaceAll('_', ' ')}</td><td className="px-4 py-2 text-gray-600">{row.employer_paid ? 'Employer' : 'Employee'}</td><td className="px-4 py-2 text-right font-medium tabular-nums">{fmt(row.amount)}</td></tr>)}</tbody>
        </table>
      </div>
    </div>
  );
}

// ─── 1099-NEC Panel ──────────────────────────────────────────────────────────

interface NecContractor {
  employee_id: number;
  name: string;
  business_name?: string;
  contractor_type: string;
  tin_type: string;
  tin_last_four?: string;
  total_compensation: number;
  federal_withheld: number;
  payment_count: number;
  requires_filing: boolean;
  w9_on_file: boolean;
  compliance_issues: string[];
}

interface NecReport {
  meta: {
    report_type: string;
    company_name: string;
    year: number;
    generated_at: string;
    contractor_count: number;
    reportable_count: number;
    filing_threshold: number;
  };
  all_contractors: NecContractor[];
  reportable_contractors: NecContractor[];
  totals: {
    total_compensation: number;
    reportable_compensation: number;
    total_federal_withheld: number;
  };
}

function Form1099NecPanel() {
  const currentYear = new Date().getFullYear();
  const [year, setYear] = useState(currentYear);
  const [report, setReport] = useState<NecReport | null>(null);
  const [loading, setLoading] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [exportingXlsx, setExportingXlsx] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadReport = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await reportsApi.form1099Nec(year);
      setReport((res as { report: NecReport }).report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load report');
    } finally {
      setLoading(false);
    }
  };

  const downloadPdf = async () => {
    setExportingPdf(true);
    try {
      const blobData = await reportsApi.form1099NecPdf(year);
      const url = URL.createObjectURL(blobData.blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `1099-NEC_${year}.pdf`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to export PDF');
    } finally {
      setExportingPdf(false);
    }
  };

  const downloadXlsx = async () => {
    setExportingXlsx(true);
    setError(null);
    try {
      const blobData = await reportsApi.form1099NecXlsx(year);
      triggerDownload(blobData.blob, blobData.filename || `1099-NEC_${year}.xlsx`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to export Excel');
    } finally {
      setExportingXlsx(false);
    }
  };

  const downloadCsv = async () => {
    setExportingCsv(true);
    setError(null);
    try {
      const blobData = await reportsApi.form1099NecCsv(year);
      triggerDownload(blobData.blob, blobData.filename || `1099-NEC_${year}.csv`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to export CSV');
    } finally {
      setExportingCsv(false);
    }
  };

  const exportFormats: ReportDownloadFormat[] = [
    { key: 'pdf', label: 'PDF report (.pdf)', description: 'Review-ready contractor summary.', kind: 'pdf', loading: exportingPdf, onSelect: downloadPdf },
    { key: 'xlsx', label: 'Excel workbook (.xlsx)', description: 'Contractor detail and filing totals.', kind: 'spreadsheet', loading: exportingXlsx, onSelect: downloadXlsx },
    { key: 'csv', label: 'Contractor data (.csv)', description: 'Flat contractor compensation data.', kind: 'data', loading: exportingCsv, onSelect: downloadCsv },
  ];

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">1099-NEC Annual Report</CardTitle>
          <CardDescription>
            Nonemployee compensation summary for 1099 contractor filing.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap items-end gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Tax Year</label>
              <select
                className="border rounded-md px-3 py-2 text-sm"
                value={year}
                onChange={(e) => setYear(Number(e.target.value))}
              >
                {Array.from({ length: 5 }, (_, i) => currentYear - i).map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
            </div>
            <Button onClick={loadReport} disabled={loading}>
              {loading ? 'Loading...' : 'View 1099-NEC Report'}
            </Button>
            {report && (
              <ReportDownloadMenu formats={exportFormats} disabled={exportingPdf || exportingXlsx || exportingCsv} />
            )}
          </div>
        </CardContent>
      </Card>

      {error && (
        <div className="p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">{error}</div>
      )}

      {report && (
        <Card>
          <CardHeader>
            <CardTitle>{report.meta.company_name} — {report.meta.year} 1099-NEC Summary</CardTitle>
            <CardDescription>
              {report.meta.contractor_count} contractor{report.meta.contractor_count !== 1 ? 's' : ''} &bull;{' '}
              {report.meta.reportable_count} reportable (&ge; ${report.meta.filing_threshold}) &bull;{' '}
              Generated {new Date(report.meta.generated_at).toLocaleString()}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
              <div className="rounded-md border border-emerald-200 bg-emerald-50 p-3">
                <p className="text-xs text-emerald-700">Total Compensation</p>
                <p className="mt-1 text-lg font-semibold">{fmt(report.totals.total_compensation)}</p>
              </div>
              <div className="rounded-md border border-emerald-200 bg-emerald-50 p-3">
                <p className="text-xs text-emerald-700">Reportable Compensation</p>
                <p className="mt-1 text-lg font-semibold">{fmt(report.totals.reportable_compensation)}</p>
              </div>
              <div className="rounded-md border p-3">
                <p className="text-xs text-gray-500">Federal Tax Withheld</p>
                <p className="mt-1 text-lg font-semibold">{fmt(report.totals.total_federal_withheld)}</p>
              </div>
            </div>

            {report.all_contractors.length === 0 ? (
              <p className="text-sm text-gray-500">No contractor payments found for {report.meta.year}.</p>
            ) : (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Contractor</TableHead>
                      <TableHead>TIN</TableHead>
                      <TableHead className="text-center">Payments</TableHead>
                      <TableHead className="text-right">Box 1 (Compensation)</TableHead>
                      <TableHead className="text-right">Box 4 (Withheld)</TableHead>
                      <TableHead className="text-center">W-9</TableHead>
                      <TableHead>Status</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {report.all_contractors.map((c) => (
                      <TableRow key={c.employee_id} className={c.compliance_issues.length > 0 ? 'bg-red-50/50' : undefined}>
                        <TableCell>
                          <p className="font-medium">{c.name}</p>
                          {c.business_name && <p className="text-xs text-gray-500">{c.business_name}</p>}
                        </TableCell>
                        <TableCell>
                          <span className="text-sm text-gray-600">{c.tin_type}: ***{c.tin_last_four || '????'}</span>
                        </TableCell>
                        <TableCell className="text-center">{c.payment_count}</TableCell>
                        <TableCell className="text-right font-medium">{fmt(c.total_compensation)}</TableCell>
                        <TableCell className="text-right">{fmt(c.federal_withheld)}</TableCell>
                        <TableCell className="text-center">
                          {c.w9_on_file ? (
                            <span className="text-emerald-600 font-medium">Yes</span>
                          ) : (
                            <span className="text-red-600 font-bold">NO</span>
                          )}
                        </TableCell>
                        <TableCell>
                          {c.requires_filing ? (
                            <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700">
                              Reportable
                            </span>
                          ) : (
                            <span className="inline-flex items-center rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600">
                              Below threshold
                            </span>
                          )}
                          {c.compliance_issues.length > 0 && (
                            <div className="mt-1">
                              {c.compliance_issues.map((issue, i) => (
                                <span key={i} className="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-[10px] font-medium text-red-700 mr-1 mb-0.5">
                                  {issue}
                                </span>
                              ))}
                            </div>
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}

// ─── Reports Center ───────────────────────────────────────────────────────────

type ReportId = 'payroll-register' | 'checks-payments-register' | 'employee-pay-history' | 'tax-withholding-summary' | 'quarterly-compliance-packet' | 'ytd-summary' | 'employer-liability' | 'w2-gu' | '1099-nec' | '941-gu';
type ReportCategory = 'all' | 'payroll' | 'tax-compliance' | 'people' | 'checks' | 'annual';

interface ReportDefinition {
  id: ReportId;
  title: string;
  description: string;
  category: Exclude<ReportCategory, 'all'>;
  basis: string;
  frequency: string;
  outputs: string[];
  cta: string;
  featured?: boolean;
  icon: ReactNode;
}

const PANELS_WITH_UI: ReportId[] = ['payroll-register', 'checks-payments-register', 'employee-pay-history', 'tax-withholding-summary', 'quarterly-compliance-packet', 'ytd-summary', 'employer-liability', 'w2-gu', '1099-nec', '941-gu'];

function reportIcon(path: ReactNode) {
  return (
    <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      {path}
    </svg>
  );
}

const reports: ReportDefinition[] = [
  {
    id: 'quarterly-compliance-packet',
    title: 'Quarterly Compliance Packet',
    description: 'W-1, SWICA, Form 500, and Federal 941 tie-out packet for firm review.',
    category: 'tax-compliance',
    basis: 'Pay date quarter',
    frequency: 'Quarterly',
    outputs: ['On-screen', 'Combined PDF', 'Excel', 'Official filing files'],
    cta: 'Open packet',
    featured: true,
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5h6m-6 4h6m-6 4h3m-6 8h12a2 2 0 002-2V7.5L14.5 3H6a2 2 0 00-2 2v14a2 2 0 002 2z" />),
  },
  {
    id: 'payroll-register',
    title: 'Payroll Register',
    description: 'Complete payroll detail for one committed pay period, including hours, taxes, deductions, and net pay.',
    category: 'payroll',
    basis: 'Pay period',
    frequency: 'Each run',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Select pay period',
    featured: true,
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.6a1 1 0 01.7.3l5.4 5.4a1 1 0 01.3.7V19a2 2 0 01-2 2z" />),
  },
  {
    id: 'ytd-summary',
    title: 'Payroll Summary by Period',
    description: 'Wage, tax, deduction, and payroll-field totals for any pay-date range.',
    category: 'payroll',
    basis: 'Pay-date range',
    frequency: 'Any period',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Choose period',
    featured: true,
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />),
  },
  {
    id: 'tax-withholding-summary',
    title: 'Tax Withholding Summary',
    description: 'Withholding totals and payroll-field reconciliation for a quarter or custom pay-date range.',
    category: 'tax-compliance',
    basis: 'Quarter or range',
    frequency: 'Any period',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Review taxes',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 7h6m0 10v-3m-3 3h.01M9 17h.01M9 14h.01M12 14h.01M15 11h.01M12 11h.01M9 11h.01M7 21h10a2 2 0 002-2V5a2 2 0 00-2-2H7a2 2 0 00-2 2v14a2 2 0 002 2z" />),
  },
  {
    id: '941-gu',
    title: 'Federal Form 941',
    description: 'Federal Form 941 worksheet for Guam employers and quarterly tie-out.',
    category: 'tax-compliance',
    basis: 'Quarter',
    frequency: 'Quarterly',
    outputs: ['On-screen', 'Official PDF', 'Excel'],
    cta: 'Open 941',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />),
  },
  {
    id: 'employer-liability',
    title: 'Employer Tax Liability',
    description: 'Employer Social Security and Medicare liability totals by year or quarter.',
    category: 'tax-compliance',
    basis: 'Pay date',
    frequency: 'Monthly/Quarterly',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Open liability',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.7 0-3 .9-3 2s1.3 2 3 2 3 .9 3 2-1.3 2-3 2m0-8c1.1 0 2.1.4 2.6 1M12 8V7m0 1v8m0 0v1m0-1c-1.1 0-2.1-.4-2.6-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />),
  },
  {
    id: 'employee-pay-history',
    title: 'Employee Pay History',
    description: 'Individual employee pay records over time for pay history review.',
    category: 'people',
    basis: 'Employee',
    frequency: 'As needed',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Choose employee',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />),
  },
  {
    id: 'checks-payments-register',
    title: 'Checks & Payments Register',
    description: 'Standalone non-pay-period checks and payments by payee, date, type, and check number.',
    category: 'checks',
    basis: 'Check date',
    frequency: 'As needed',
    outputs: ['On-screen', 'CSV'],
    cta: 'Review checks',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 14h6m-7 4h8M7 4h10a2 2 0 012 2v12a2 2 0 01-2 2H7a2 2 0 01-2-2V6a2 2 0 012-2zm2 4h6" />),
  },
  {
    id: 'w2-gu',
    title: 'W-2GU Annual Report',
    description: 'Guam territorial W-2 preparation summary and filing readiness checks.',
    category: 'annual',
    basis: 'Calendar year',
    frequency: 'Annual',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Prepare W-2GU',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.6a1 1 0 01.7.3l5.4 5.4a1 1 0 01.3.7V19a2 2 0 01-2 2z" />),
  },
  {
    id: '1099-nec',
    title: '1099-NEC Annual Report',
    description: 'Nonemployee compensation summary for contractor 1099 filing.',
    category: 'annual',
    basis: 'Calendar year',
    frequency: 'Annual',
    outputs: ['On-screen', 'PDF', 'Excel', 'CSV'],
    cta: 'Prepare 1099s',
    icon: reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 20h5v-2a3 3 0 00-5.4-1.9M17 20H7m10 0v-2c0-.7-.1-1.3-.4-1.9M7 20H2v-2a3 3 0 015.4-1.9M7 20v-2c0-.7.1-1.3.4-1.9m0 0a5 5 0 019.2 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" />),
  },
];

const reportCategories: Array<{ id: ReportCategory; label: string }> = [
  { id: 'all', label: 'All reports' },
  { id: 'payroll', label: 'Payroll' },
  { id: 'tax-compliance', label: 'Tax & compliance' },
  { id: 'people', label: 'Employees' },
  { id: 'checks', label: 'Checks' },
  { id: 'annual', label: 'Annual filing' },
];

const FAVORITES_KEY_PREFIX = 'cornerstone-report-favorites';
const RECENTS_KEY_PREFIX = 'cornerstone-report-recents';

function reportStorageKey(prefix: string, scope: string) {
  return `${prefix}:${scope}`;
}

function readStoredReportIds(key: string): ReportId[] {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || '[]');
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((id): id is ReportId => reports.some((report) => report.id === id));
  } catch {
    return [];
  }
}

function writeStoredReportIds(key: string, ids: ReportId[]) {
  try {
    localStorage.setItem(key, JSON.stringify(ids));
  } catch {
    // Ignore storage failures; reports remain usable without personalization.
  }
}

function ReportMetaChips({ report }: { report: ReportDefinition }) {
  return (
    <div className="mt-3 flex flex-wrap gap-2">
      <span className="rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-semibold text-neutral-600">Basis: {report.basis}</span>
      <span className="rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-semibold text-neutral-600">{report.frequency}</span>
      <span className="rounded-full bg-primary-50 px-2.5 py-1 text-xs font-semibold text-primary-700">{report.outputs.join(' · ')}</span>
    </div>
  );
}

function FavoriteButton({ active, onClick }: { active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      aria-label={active ? 'Remove from favorites' : 'Add to favorites'}
      onClick={(event) => {
        event.stopPropagation();
        onClick();
      }}
      className={`inline-flex h-8 w-8 items-center justify-center rounded-full border transition-colors ${
        active
          ? 'border-accent-200 bg-accent-50 text-accent-700'
          : 'border-neutral-200 bg-white text-neutral-400 hover:border-accent-200 hover:text-accent-700'
      }`}
    >
      <svg className="h-4 w-4" viewBox="0 0 24 24" fill={active ? 'currentColor' : 'none'} stroke="currentColor" aria-hidden="true">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M11.5 3.6a.6.6 0 011 0l2.4 4.9 5.4.8a.6.6 0 01.3 1l-3.9 3.8.9 5.4a.6.6 0 01-.9.6L12 17.6l-4.8 2.5a.6.6 0 01-.9-.6l.9-5.4-3.9-3.8a.6.6 0 01.3-1l5.4-.8 2.5-4.9z" />
      </svg>
    </button>
  );
}

function ReportLibraryRow({
  report,
  active,
  favorite,
  onOpen,
  onToggleFavorite,
}: {
  report: ReportDefinition;
  active: boolean;
  favorite: boolean;
  onOpen: () => void;
  onToggleFavorite: () => void;
}) {
  return (
    <Card
      className={`cursor-pointer overflow-hidden transition-all hover:-translate-y-0.5 hover:border-primary-200 ${active ? 'border-primary-300 bg-primary-50/45' : ''}`}
      onClick={onOpen}
    >
      <CardContent className="p-5">
        <div className="flex items-start gap-4">
          <div className={`rounded-2xl p-3 ring-1 ${active ? 'bg-primary-100 text-primary-700 ring-primary-200' : 'bg-primary-50 text-primary-700 ring-primary-100'}`}>
            {report.icon}
          </div>
          <div className="min-w-0 flex-1">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h3 className="font-display text-base font-extrabold tracking-tight text-neutral-950">{report.title}</h3>
                <p className="mt-1 text-sm leading-6 text-neutral-500">{report.description}</p>
              </div>
              <FavoriteButton active={favorite} onClick={onToggleFavorite} />
            </div>
            <ReportMetaChips report={report} />
            <div className="mt-4 flex items-center justify-between gap-3 border-t border-neutral-100 pt-4">
              <span className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{reportCategories.find((category) => category.id === report.category)?.label}</span>
              <Button size="sm" variant={active ? 'primary' : 'outline'} onClick={(event) => { event.stopPropagation(); onOpen(); }}>
                {active ? 'Selected' : report.cta}
              </Button>
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function EmptyReportSearch({ onClear }: { onClear: () => void }) {
  return (
    <Card>
      <CardContent className="flex flex-col items-center justify-center px-4 py-10 text-center sm:px-6">
        <div className="rounded-2xl bg-neutral-100 p-3 text-neutral-500">
          {reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-4.3-4.3m1.8-5.2a7 7 0 11-14 0 7 7 0 0114 0z" />)}
        </div>
        <h3 className="mt-4 font-display text-lg font-extrabold text-neutral-950">No reports found</h3>
        <p className="mt-1 max-w-md text-sm text-neutral-500">Try a different search term or switch back to all report categories.</p>
        <Button className="mt-5" variant="secondary" onClick={onClear}>Clear filters</Button>
      </CardContent>
    </Card>
  );
}

// ─── Page ────────────────────────────────────────────────────────────────────

export function Reports() {
  const { user } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();
  const reportParam = searchParams.get('report');
  const activeReport = reports.some((report) => report.id === reportParam) ? (reportParam as ReportId) : null;
  const [query, setQuery] = useState('');
  const [activeCategory, setActiveCategory] = useState<ReportCategory>('all');
  const storageScope = user
    ? `org-${user.organization_id ?? 'none'}:company-${user.company_id}:user-${user.id}`
    : 'anonymous';
  const favoritesKey = reportStorageKey(FAVORITES_KEY_PREFIX, storageScope);
  const recentsKey = reportStorageKey(RECENTS_KEY_PREFIX, storageScope);
  const [favoritesState, setFavoritesState] = useState(() => ({
    key: favoritesKey,
    ids: readStoredReportIds(favoritesKey),
  }));
  const [recentReportsState, setRecentReportsState] = useState(() => ({
    key: recentsKey,
    ids: readStoredReportIds(recentsKey),
  }));
  const favorites = favoritesState.key === favoritesKey ? favoritesState.ids : readStoredReportIds(favoritesKey);
  const recentReports = recentReportsState.key === recentsKey ? recentReportsState.ids : readStoredReportIds(recentsKey);

  const activeReportDefinition = reports.find((report) => report.id === activeReport) || null;

  const openReport = (reportId: ReportId) => {
    setSearchParams({ report: reportId });
    setRecentReportsState((current) => {
      const currentIds = current.key === recentsKey ? current.ids : readStoredReportIds(recentsKey);
      const next = [reportId, ...currentIds.filter((id) => id !== reportId)].slice(0, 4);
      writeStoredReportIds(recentsKey, next);
      return { key: recentsKey, ids: next };
    });
  };

  const toggleFavorite = (reportId: ReportId) => {
    setFavoritesState((current) => {
      const currentIds = current.key === favoritesKey ? current.ids : readStoredReportIds(favoritesKey);
      const next = currentIds.includes(reportId)
        ? currentIds.filter((id) => id !== reportId)
        : [reportId, ...currentIds];
      writeStoredReportIds(favoritesKey, next);
      return { key: favoritesKey, ids: next };
    });
  };

  const filteredReports = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return reports.filter((report) => {
      const matchesCategory = activeCategory === 'all' || report.category === activeCategory;
      const matchesQuery = !needle || [
        report.title,
        report.description,
        report.basis,
        report.frequency,
        report.outputs.join(' '),
      ].join(' ').toLowerCase().includes(needle);
      return matchesCategory && matchesQuery;
    });
  }, [activeCategory, query]);

  const favoriteReports = favorites.map((id) => reports.find((report) => report.id === id)).filter((report): report is ReportDefinition => Boolean(report));
  const recentReportDefinitions = recentReports.map((id) => reports.find((report) => report.id === id)).filter((report): report is ReportDefinition => Boolean(report));
  const recommendedReports = favoriteReports.length > 0 ? favoriteReports.slice(0, 3) : reports.filter((report) => report.featured);

  const renderActivePanel = () => {
    if (activeReport === 'payroll-register') return <PayrollRegisterPanel />;
    if (activeReport === 'checks-payments-register') return <ChecksPaymentsRegisterPanel />;
    if (activeReport === 'employee-pay-history') return <EmployeePayHistoryPanel />;
    if (activeReport === 'tax-withholding-summary') return <TaxSummaryPanel />;
    if (activeReport === 'quarterly-compliance-packet') return <QuarterlyCompliancePacketPanel />;
    if (activeReport === 'ytd-summary') return <YtdSummaryPanel />;
    if (activeReport === 'employer-liability') return <EmployerLiabilityPanel />;
    if (activeReport === 'w2-gu') return <W2GuPanel />;
    if (activeReport === '1099-nec') return <Form1099NecPanel />;
    if (activeReport === '941-gu') return <Form941GuPanel />;
    if (activeReport && !PANELS_WITH_UI.includes(activeReport)) {
      return (
        <Card>
          <CardHeader>
            <CardTitle>{reports.find((r) => r.id === activeReport)?.title}</CardTitle>
            <CardDescription>This report is not yet available in the UI.</CardDescription>
          </CardHeader>
        </Card>
      );
    }
    return null;
  };

  return (
    <div>
      <Header title="Reports" description="Find, prepare, and export payroll and Guam compliance reports." />

      <div className="space-y-8 p-4 sm:p-6 lg:p-8">
        <Card className="overflow-hidden border-primary-200/80 bg-[linear-gradient(135deg,#ffffff_0%,#f4f8ff_55%,#fff8eb_100%)]">
          <CardContent className="p-4 sm:p-6 lg:p-7">
            <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-center">
              <div>
                <p className="text-xs font-extrabold uppercase tracking-[0.16em] text-primary-700">Reports center</p>
                <h2 className="mt-2 font-display text-3xl font-extrabold tracking-tight text-neutral-950 text-balance">Everything payroll teams need to file, reconcile, and review.</h2>
                <p className="mt-3 max-w-3xl text-sm leading-6 text-neutral-600">
                  Search the report library, open a focused setup panel, and export packet-ready payroll records. Report basis and output formats are shown up front so operators know exactly what they are running.
                </p>
                <p className="mt-3 inline-flex rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-xs font-bold text-emerald-800">
                  View reports in Cornerstone first. Export only when you need to share, print, file, or analyze.
                </p>
              </div>
              <div className="rounded-2xl border border-white/80 bg-white/75 p-4 shadow-sm shadow-primary-100/70">
                <p className="text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">Recommended workflow</p>
                <div className="mt-3 space-y-2 text-sm text-neutral-600">
                  <p><span className="font-bold text-neutral-950">1.</span> Pick a report or packet.</p>
                  <p><span className="font-bold text-neutral-950">2.</span> Confirm period, quarter, or employee.</p>
                  <p><span className="font-bold text-neutral-950">3.</span> Preview, reconcile, then export.</p>
                </div>
              </div>
            </div>

            <div className="mt-6 grid gap-3 lg:grid-cols-[minmax(0,1fr)_auto]">
              <label className="relative block">
                <span className="sr-only">Search reports</span>
                <span className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-neutral-400">
                  {reportIcon(<path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-4.3-4.3m1.8-5.2a7 7 0 11-14 0 7 7 0 0114 0z" />)}
                </span>
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="Search by report name, basis, output, or filing type…"
                  className="h-12 w-full rounded-full border border-neutral-200 bg-white/90 pl-12 pr-4 text-sm font-medium text-neutral-900 shadow-sm shadow-neutral-200/50 outline-none transition focus:border-primary-300 focus:ring-2 focus:ring-primary-100"
                />
              </label>
              <div className="flex flex-wrap items-center gap-2">
                {reportCategories.map((category) => (
                  <button
                    key={category.id}
                    type="button"
                    onClick={() => setActiveCategory(category.id)}
                    className={`rounded-full px-4 py-2 text-sm font-bold transition-colors ${
                      activeCategory === category.id
                        ? 'bg-primary-700 text-white shadow-sm shadow-primary-700/20'
                        : 'border border-neutral-200 bg-white/85 text-neutral-600 hover:border-primary-200 hover:text-primary-800'
                    }`}
                  >
                    {category.label}
                  </button>
                ))}
              </div>
            </div>
          </CardContent>
        </Card>

        <section aria-labelledby="recommended-reports-heading">
          <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 id="recommended-reports-heading" className="font-display text-xl font-extrabold tracking-tight text-neutral-950">
                {favoriteReports.length > 0 ? 'Favorite reports' : 'Recommended reports'}
              </h2>
              <p className="text-sm text-neutral-500">
                {favoriteReports.length > 0 ? 'Pinned reports appear here for quick access.' : 'Start with the reports most firms use during payroll and quarterly filing.'}
              </p>
            </div>
            {recentReportDefinitions.length > 0 && (
              <div className="flex flex-wrap items-center gap-2 text-sm">
                <span className="font-bold text-neutral-500">Recent:</span>
                {recentReportDefinitions.map((report) => (
                  <button key={report.id} type="button" onClick={() => openReport(report.id)} className="rounded-full bg-neutral-100 px-3 py-1 font-semibold text-neutral-600 transition-colors hover:bg-primary-50 hover:text-primary-700">
                    {report.title}
                  </button>
                ))}
              </div>
            )}
          </div>

          <div className="grid gap-4 lg:grid-cols-3">
            {recommendedReports.map((report) => (
              <ReportLibraryRow
                key={report.id}
                report={report}
                active={activeReport === report.id}
                favorite={favorites.includes(report.id)}
                onOpen={() => openReport(report.id)}
                onToggleFavorite={() => toggleFavorite(report.id)}
              />
            ))}
          </div>
        </section>

        {activeReportDefinition && (
          <section aria-labelledby="active-report-heading" className="scroll-mt-6">
            <div className="mb-4 rounded-[1.35rem] border border-primary-200 bg-white/90 p-5 shadow-sm shadow-primary-100/60">
              <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <div className="flex items-start gap-4">
                  <div className="rounded-2xl bg-primary-100 p-3 text-primary-700 ring-1 ring-primary-200">{activeReportDefinition.icon}</div>
                  <div>
                    <p className="text-xs font-extrabold uppercase tracking-[0.14em] text-primary-700">Selected report</p>
                    <h2 id="active-report-heading" className="font-display text-2xl font-extrabold tracking-tight text-neutral-950">{activeReportDefinition.title}</h2>
                    <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-500">{activeReportDefinition.description}</p>
                    <ReportMetaChips report={activeReportDefinition} />
                  </div>
                </div>
                <Button
                  variant="secondary"
                  onClick={() => {
                    setSearchParams({});
                  }}
                >
                  Close report
                </Button>
              </div>
            </div>
            {renderActivePanel()}
          </section>
        )}

        <section aria-labelledby="report-library-heading">
          <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 id="report-library-heading" className="font-display text-xl font-extrabold tracking-tight text-neutral-950">Report library</h2>
              <p className="text-sm text-neutral-500">{filteredReports.length} report{filteredReports.length === 1 ? '' : 's'} available</p>
            </div>
            {(query || activeCategory !== 'all') && (
              <Button variant="ghost" size="sm" onClick={() => { setQuery(''); setActiveCategory('all'); }}>
                Clear filters
              </Button>
            )}
          </div>

          {filteredReports.length === 0 ? (
            <EmptyReportSearch onClear={() => { setQuery(''); setActiveCategory('all'); }} />
          ) : (
            <div className="grid gap-4 xl:grid-cols-2">
              {filteredReports.map((report) => (
                <ReportLibraryRow
                  key={report.id}
                  report={report}
                  active={activeReport === report.id}
                  favorite={favorites.includes(report.id)}
                  onOpen={() => openReport(report.id)}
                  onToggleFavorite={() => toggleFavorite(report.id)}
                />
              ))}
            </div>
          )}
        </section>

        <Card className="border-dashed">
          <CardHeader>
            <CardTitle>Planned reports</CardTitle>
            <CardDescription>Additional exports queued for future releases.</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="flex items-center gap-3 rounded-2xl bg-neutral-50 px-4 py-3 text-sm text-neutral-600">
              <span className="h-2 w-2 rounded-full bg-neutral-300" />
              General Ledger Export
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
