import { useState, useEffect, type ReactNode } from 'react';
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
import type { PayrollRegisterReport, TaxSummaryReport, YtdSummaryReport, Form941GuReport } from '@/services/api';
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
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<PayrollRegisterReport['report'] | null>(null);

  useEffect(() => {
    payPeriodsApi.list({ status: 'committed' })
      .then((res) => {
        const periods = res.pay_periods ?? [];
        const sorted = [...periods].sort((a, b) => {
          const aDate = Date.parse(a.pay_date || '');
          const bDate = Date.parse(b.pay_date || '');
          if (!Number.isNaN(aDate) && !Number.isNaN(bDate)) return bDate - aDate;
          return b.id - a.id;
        });
        setPayPeriods(sorted);
        if (sorted.length > 0) setSelectedPeriodId(sorted[0].id);
      })
      .catch(() => setError('Failed to load pay periods'))
      .finally(() => setLoadingPeriods(false));
  }, []);

  const busy = loading || exportingCsv || exportingPdf;

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
          <div className="flex flex-wrap items-center gap-4">
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
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
            <div className="flex items-center gap-2 ml-auto">
              <Button
                variant="outline"
                size="sm"
                onClick={downloadCsv}
                disabled={busy || !selectedPeriodId}
                title="Download Payroll Register as CSV"
              >
                {exportingCsv ? 'Exporting…' : '⬇ Download CSV'}
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={downloadPdf}
                disabled={busy || !selectedPeriodId}
                title="Download Payroll Register as PDF"
              >
                {exportingPdf ? 'Exporting…' : '⬇ Download PDF'}
              </Button>
            </div>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>
                Payroll Register — {report.pay_period.start_date} to {report.pay_period.end_date}
              </CardTitle>
              <CardDescription>
                Pay Date: {report.pay_period.pay_date} &bull; {report.summary.employee_count} employee{report.summary.employee_count !== 1 ? 's' : ''}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
                <TotalBox label="Total Gross Pay" value={report.summary.total_gross} />
                <TotalBox label="Total Withholding" value={report.summary.total_withholding} />
                <TotalBox label="Total Deductions" value={report.summary.total_deductions} />
                <TotalBox label="Total Net Pay" value={report.summary.total_net} />
              </div>
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
                    <th className="pb-2 pr-4 font-medium">Employee</th>
                    <th className="pb-2 pr-4 font-medium">Type</th>
                    <th className="pb-2 pr-4 font-medium text-right">Hours</th>
                    <th className="pb-2 pr-4 font-medium text-right">Gross Pay</th>
                    <th className="pb-2 pr-4 font-medium text-right">Withholding</th>
                    <th className="pb-2 pr-4 font-medium text-right">Addtl W/H</th>
                    <th className="pb-2 pr-4 font-medium text-right">SS Tax</th>
                    <th className="pb-2 pr-4 font-medium text-right">Medicare</th>
                    <th className="pb-2 pr-4 font-medium text-right">Retirement</th>
                    <th className="pb-2 pr-4 font-medium text-right">Net Pay</th>
                    <th className="pb-2 font-medium">Check #</th>
                  </tr>
                </thead>
                <tbody>
                  {report.employees.map((emp) => (
                    <tr key={emp.employee_id} className="border-b last:border-0 hover:bg-gray-50">
                      <td className="py-2 pr-4 font-medium">{emp.employee_name}</td>
                      <td className="py-2 pr-4 capitalize text-gray-500">{emp.employment_type}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{emp.hours_worked ?? '—'}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.gross_pay ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.withholding_tax ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.additional_withholding ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.social_security_tax ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.medicare_tax ?? 0)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">
                        {fmt(emp.total_retirement_payment ?? ((emp.retirement_payment ?? 0) + (emp.roth_retirement_payment ?? 0)))}
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums font-semibold">{fmt(emp.net_pay ?? 0)}</td>
                      <td className="py-2 font-mono text-gray-500">{emp.check_number ?? '—'}</td>
                    </tr>
                  ))}
                  {report.employees.length === 0 && (
                    <tr>
                      <td colSpan={11} className="py-6 text-center text-gray-400">
                        No payroll items found for this pay period.
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
  const [loading, setLoading] = useState(false);
  const [exportingCsv, setExportingCsv] = useState(false);
  const [exportingPdf, setExportingPdf] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TaxSummaryReport['report'] | null>(null);

  const busy = loading || exportingCsv || exportingPdf;

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.taxSummary(year, quarter);
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
      const { blob, filename } = await reportsApi.taxSummaryCsv(year, quarter);
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
      const { blob, filename } = await reportsApi.taxSummaryPdf(year, quarter);
      triggerDownload(blob, filename || `tax_summary_${year}${quarter ? `_q${quarter}` : ''}.pdf`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setExportingPdf(false);
    }
  }

  const periodLabel = quarter ? `Q${quarter} ${year}` : `${year} Full Year`;

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
          <div className="flex flex-wrap items-center gap-4">
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
            <Button onClick={loadReport} disabled={busy}>
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
            <div className="flex items-center gap-2 ml-auto">
              <Button
                variant="outline"
                size="sm"
                onClick={downloadCsv}
                disabled={busy}
                title={`Download Tax Summary CSV for ${periodLabel}`}
              >
                {exportingCsv ? 'Exporting…' : '⬇ Download CSV'}
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={downloadPdf}
                disabled={busy}
                title={`Download Tax Summary PDF for ${periodLabel}`}
              >
                {exportingPdf ? 'Exporting…' : '⬇ Download PDF'}
              </Button>
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
              {report.pay_periods_included} pay period{report.pay_periods_included !== 1 ? 's' : ''} &bull;{' '}
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

  const busy = loading || exportingCsv || exportingPdf || preflightLoading || markingReady;

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
          <div className="flex flex-wrap items-center gap-4">
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
              {loading ? 'Loading…' : 'Generate W-2GU Report'}
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

            {/* Export buttons */}
            <div className="flex items-center gap-2 ml-auto">
              <Button
                variant="outline"
                size="sm"
                onClick={downloadCsv}
                disabled={busy}
                title={`Download W-2GU CSV for ${year}`}
              >
                {exportingCsv ? 'Exporting…' : '⬇ Download CSV'}
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={downloadPdf}
                disabled={busy}
                title={`Download W-2GU PDF for ${year}`}
              >
                {exportingPdf ? 'Exporting…' : '⬇ Download PDF'}
              </Button>
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
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loadingEmployees, setLoadingEmployees] = useState(true);
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<{
    employee: { id: number; name: string; employment_type: string; pay_rate: number };
    history: {
      pay_period_id: number;
      pay_date: string;
      period_description: string;
      hours_worked: number | null;
      overtime_hours: number | null;
      gross_pay: number;
      total_deductions: number;
      net_pay: number;
      check_number: string | null;
    }[];
    ytd: Record<string, number>;
  } | null>(null);

  useEffect(() => {
    employeesApi.list({ status: 'active', per_page: 500 })
      .then((res) => {
        const list = res.data ?? [];
        list.sort((a, b) => (a.last_name || '').localeCompare(b.last_name || ''));
        setEmployees(list);
        if (list.length > 0) setSelectedEmployeeId(list[0].id);
      })
      .catch(() => setError('Failed to load employees'))
      .finally(() => setLoadingEmployees(false));
  }, []);

  async function loadReport() {
    if (!selectedEmployeeId) return;
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.employeePayHistory(selectedEmployeeId);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Employee Pay History</CardTitle>
          <CardDescription>
            Individual employee pay records across recent committed pay periods.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap items-center gap-4">
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
            <Button onClick={loadReport} disabled={loading || !selectedEmployeeId}>
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
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
                {report.employee.employment_type} &bull; Rate: {fmt(report.employee.pay_rate)}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 mb-6">
                <TotalBox label="YTD Gross Pay" value={report.ytd.gross_pay ?? 0} />
                <TotalBox label="YTD Withholding" value={report.ytd.withholding_tax ?? 0} />
                <TotalBox label="YTD SS Tax" value={report.ytd.social_security_tax ?? 0} />
                <TotalBox label="YTD Medicare" value={report.ytd.medicare_tax ?? 0} />
                <TotalBox label="YTD Retirement" value={report.ytd.retirement ?? 0} />
                <TotalBox label="YTD Net Pay" value={report.ytd.net_pay ?? 0} />
              </div>
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
                    <th className="pb-2 pr-4 font-medium text-right">Gross Pay</th>
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
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.gross_pay)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(h.total_deductions)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums font-semibold">{fmt(h.net_pay)}</td>
                      <td className="py-2 font-mono text-gray-500">{h.check_number ?? '—'}</td>
                    </tr>
                  ))}
                  {report.history.length === 0 && (
                    <tr>
                      <td colSpan={8} className="py-6 text-center text-gray-400">
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
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<YtdSummaryReport['report'] | null>(null);

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.ytdSummary(year);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Year-to-Date Summary</CardTitle>
          <CardDescription>
            YTD payroll totals for all employees — gross, taxes, retirement, and net pay.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap items-center gap-4">
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
            <Button onClick={loadReport} disabled={loading}>
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>YTD Summary — {report.year}</CardTitle>
              <CardDescription>
                {report.employees.length} employee{report.employees.length !== 1 ? 's' : ''}
                {report.company_totals?.payroll_count != null && (
                  <> &bull; {report.company_totals.payroll_count} payroll{report.company_totals.payroll_count !== 1 ? 's' : ''}</>
                )}
              </CardDescription>
            </CardHeader>
            <CardContent>
              {report.company_totals && (
                <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 mb-6">
                  <TotalBox label="Total Gross Pay" value={report.company_totals.gross_pay} />
                  <TotalBox label="Total Withholding" value={report.company_totals.withholding_tax} />
                  <TotalBox label="Total SS Tax" value={report.company_totals.social_security_tax} />
                  <TotalBox label="Total Medicare" value={report.company_totals.medicare_tax} />
                  <TotalBox label="Total Retirement" value={report.company_totals.retirement} />
                  <TotalBox label="Total Net Pay" value={report.company_totals.net_pay} />
                </div>
              )}
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
                    <th className="pb-2 pr-4 font-medium">Employee</th>
                    <th className="pb-2 pr-4 font-medium">Type</th>
                    <th className="pb-2 pr-4 font-medium">Status</th>
                    <th className="pb-2 pr-4 font-medium text-right">Gross Pay</th>
                    <th className="pb-2 pr-4 font-medium text-right">Withholding</th>
                    <th className="pb-2 pr-4 font-medium text-right">SS Tax</th>
                    <th className="pb-2 pr-4 font-medium text-right">Medicare</th>
                    <th className="pb-2 pr-4 font-medium text-right">Retirement</th>
                    <th className="pb-2 font-medium text-right">Net Pay</th>
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
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.withholding_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.social_security_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.medicare_tax)}</td>
                      <td className="py-2 pr-4 text-right tabular-nums">{fmt(emp.retirement)}</td>
                      <td className="py-2 text-right tabular-nums font-semibold">{fmt(emp.net_pay)}</td>
                    </tr>
                  ))}
                  {report.employees.length === 0 && (
                    <tr>
                      <td colSpan={9} className="py-6 text-center text-gray-400">
                        No employee data found for {report.year}.
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
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TaxSummaryReport['report'] | null>(null);

  async function loadReport() {
    setLoading(true);
    setError(null);
    setReport(null);
    try {
      const res = await reportsApi.taxSummary(year, quarter);
      setReport(res.report);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

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
          <div className="flex flex-wrap items-center gap-4">
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
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
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

// ─── Form 941-GU Panel ────────────────────────────────────────────────────────

function Form941GuPanel() {
  const currentYear = new Date().getFullYear();
  const yearOptions = Array.from({ length: currentYear - 2020 + 1 }, (_, i) => currentYear - i);
  const currentQuarter = Math.ceil((new Date().getMonth() + 1) / 3);
  const [year, setYear] = useState(currentYear);
  const [quarter, setQuarter] = useState(currentQuarter);
  const [loading, setLoading] = useState(false);
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

  const fmtOrPlaceholder = (v: number | null) => v != null ? fmt(v) : '—';

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Form 941-GU Quarterly Report</CardTitle>
          <CardDescription>
            Guam Employer's Quarterly Federal Tax Return — mirrors federal Form 941 for DRT filing.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap items-center gap-4">
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
              {loading ? 'Loading…' : 'Generate Report'}
            </Button>
          </div>
          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        </CardContent>
      </Card>

      {report && (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Form 941-GU — {report.meta.quarter_label}</CardTitle>
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
                        <td className="px-4 py-2">Wages, tips, and other compensation</td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line2_wages_tips_other)}</td>
                        <td className="px-4 py-2 text-right"></td>
                      </tr>
                      <tr className="border-b">
                        <td className="px-4 py-2 font-mono text-gray-500">3</td>
                        <td className="px-4 py-2">Federal income tax withheld</td>
                        <td className="px-4 py-2 text-right"></td>
                        <td className="px-4 py-2 text-right tabular-nums">{fmt(report.lines.line3_fit_withheld)}</td>
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
                        <td className="px-4 py-2">Total taxes before adjustments (line 3 + 5e)</td>
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
                            <th className="text-right px-4 py-2 font-medium text-gray-600">FIT Withheld</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">SS Combined</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Medicare Combined</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Addtl Medicare</th>
                            <th className="text-right px-4 py-2 font-medium text-gray-600">Total Liability</th>
                          </tr>
                        </thead>
                        <tbody>
                          {report.monthly_liability.map((m) => (
                            <tr key={m.month} className="border-b last:border-0">
                              <td className="px-4 py-2">{m.month_name}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.fit_withheld)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.ss_combined)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.medicare_combined)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{fmt(m.additional_medicare)}</td>
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
              {loading ? 'Loading...' : 'Generate 1099-NEC Report'}
            </Button>
            {report && (
              <Button variant="outline" onClick={downloadPdf} disabled={exportingPdf}>
                {exportingPdf ? 'Exporting...' : 'Download PDF'}
              </Button>
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

// ─── Report Tiles ─────────────────────────────────────────────────────────────

type ReportId = 'payroll-register' | 'employee-pay-history' | 'tax-withholding-summary' | 'ytd-summary' | 'employer-liability' | 'w2-gu' | '1099-nec' | '941-gu';

const PANELS_WITH_UI: ReportId[] = ['payroll-register', 'employee-pay-history', 'tax-withholding-summary', 'ytd-summary', 'employer-liability', 'w2-gu', '1099-nec', '941-gu'];

const reports: { id: ReportId; title: string; description: string; icon: ReactNode }[] = [
  {
    id: 'payroll-register',
    title: 'Payroll Register',
    description: 'Complete payroll details for a selected pay period',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
      </svg>
    ),
  },
  {
    id: 'employee-pay-history',
    title: 'Employee Pay History',
    description: 'Individual employee pay records over time',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
      </svg>
    ),
  },
  {
    id: 'tax-withholding-summary',
    title: 'Tax Withholding Summary',
    description: 'Quarterly tax withholding totals for filing',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 7h6m0 10v-3m-3 3h.01M9 17h.01M9 14h.01M12 14h.01M15 11h.01M12 11h.01M9 11h.01M7 21h10a2 2 0 002-2V5a2 2 0 00-2-2H7a2 2 0 00-2 2v14a2 2 0 002 2z" />
      </svg>
    ),
  },
  {
    id: 'ytd-summary',
    title: 'Year-to-Date Summary',
    description: 'YTD totals for all employees',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
      </svg>
    ),
  },
  {
    id: 'employer-liability',
    title: 'Employer Tax Liability',
    description: 'Employer portion of payroll taxes',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
    ),
  },
  {
    id: 'w2-gu',
    title: 'W-2GU Annual Report',
    description: 'Guam territorial W-2 preparation summary for DRT filing',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
      </svg>
    ),
  },
  {
    id: '1099-nec',
    title: '1099-NEC Annual Report',
    description: 'Nonemployee compensation summary for 1099 contractor filing',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" />
      </svg>
    ),
  },
  {
    id: '941-gu',
    title: 'Form 941-GU Quarterly',
    description: 'Quarterly federal tax return for Guam employers (DRT filing)',
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />
      </svg>
    ),
  },
];

// ─── Page ────────────────────────────────────────────────────────────────────

export function Reports() {
  const [activeReport, setActiveReport] = useState<ReportId | null>(null);

  return (
    <div>
      <Header
        title="Reports"
        description="Generate payroll and tax reports"
      />

      <div className="p-8 space-y-8">
        {/* Report tiles */}
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
          {reports.map((report) => {
            const isActive = activeReport === report.id;
            return (
              <Card
                key={report.id}
                className={`transition-colors cursor-pointer ${isActive ? 'border-primary-500 bg-primary-50' : 'hover:border-primary-300'}`}
                onClick={() => setActiveReport(isActive ? null : report.id)}
              >
                <CardHeader>
                  <div className="flex items-start gap-4">
                    <div className={`p-2 rounded-lg ${isActive ? 'bg-primary-200 text-primary-700' : 'bg-primary-100 text-primary-600'}`}>
                      {report.icon}
                    </div>
                    <div>
                      <CardTitle className="text-base">{report.title}</CardTitle>
                      <CardDescription className="mt-1">{report.description}</CardDescription>
                    </div>
                  </div>
                </CardHeader>
                <CardContent>
                  <Button
                    variant={isActive ? 'primary' : 'outline'}
                    size="sm"
                    className="w-full"
                    onClick={(e) => {
                      e.stopPropagation();
                      setActiveReport(isActive ? null : report.id);
                    }}
                  >
                    {isActive ? 'Hide Report' : 'Generate Report'}
                  </Button>
                </CardContent>
              </Card>
            );
          })}
        </div>

        {/* Active report panel */}
        {activeReport === 'payroll-register' && <PayrollRegisterPanel />}
        {activeReport === 'employee-pay-history' && <EmployeePayHistoryPanel />}
        {activeReport === 'tax-withholding-summary' && <TaxSummaryPanel />}
        {activeReport === 'ytd-summary' && <YtdSummaryPanel />}
        {activeReport === 'employer-liability' && <EmployerLiabilityPanel />}
        {activeReport === 'w2-gu' && <W2GuPanel />}
        {activeReport === '1099-nec' && <Form1099NecPanel />}
        {activeReport === '941-gu' && <Form941GuPanel />}

        {/* Placeholder for other reports not yet wired */}
        {activeReport && !PANELS_WITH_UI.includes(activeReport) && (
          <Card>
            <CardHeader>
              <CardTitle>{reports.find((r) => r.id === activeReport)?.title}</CardTitle>
              <CardDescription>This report is not yet available in the UI.</CardDescription>
            </CardHeader>
          </Card>
        )}

        {/* Coming Soon */}
        <Card>
          <CardHeader>
            <CardTitle>Coming Soon</CardTitle>
            <CardDescription>Additional reports for future releases</CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="space-y-2 text-sm text-gray-600">
              <li className="flex items-center gap-2">
                <span className="w-2 h-2 bg-gray-300 rounded-full" />
                General Ledger Export
              </li>
            </ul>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
