import { useEffect, useState } from 'react';
import { AlertTriangle, CheckCircle2, Eye, FileCheck2, Loader2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { ReportDownloadMenu } from '@/components/reports/ReportDownloadMenu';
import { reportsApi, type PayrollFinalRecord } from '@/services/api';

interface Props {
  payPeriodId: number;
}

const money = (value: string) => new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', minimumFractionDigits: 2,
}).format(Number(value));

const humanize = (value: string) => value.replaceAll('_', ' ').replace(/\b\w/g, letter => letter.toUpperCase());

function StatusMark({ good, label }: { good: boolean; label: string }) {
  return (
    <span className={`inline-flex items-center gap-1.5 text-sm font-medium ${good ? 'text-emerald-700' : 'text-amber-700'}`}>
      {good ? <CheckCircle2 className="h-4 w-4" aria-hidden="true" /> : <AlertTriangle className="h-4 w-4" aria-hidden="true" />}
      {label}
    </span>
  );
}

function download(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

export function PayrollFinalRecordPanel({ payPeriodId }: Props) {
  const [record, setRecord] = useState<PayrollFinalRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [exporting, setExporting] = useState<'xlsx' | 'pdf' | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    reportsApi.payrollFinalRecord(payPeriodId)
      .then(({ final_record }) => { if (active) setRecord(final_record); })
      .catch((cause) => { if (active) setError(cause instanceof Error ? cause.message : 'Unable to load the final payroll record'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [payPeriodId]);

  const exportRecord = async (format: 'xlsx' | 'pdf') => {
    setExporting(format);
    setError(null);
    try {
      const result = format === 'xlsx'
        ? await reportsApi.payrollFinalRecordXlsx(payPeriodId)
        : await reportsApi.payrollFinalRecordPdf(payPeriodId);
      download(result.blob, `final_payroll_record.${format}`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to export the final payroll record');
    } finally {
      setExporting(null);
    }
  };

  const complete = record?.completion.status === 'complete';
  const attention = record?.completion.status === 'attention_required';

  return (
    <>
      <Card className="overflow-hidden border-slate-200">
        <div className="flex flex-col gap-4 bg-gradient-to-r from-slate-50 to-white p-5 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex min-w-0 gap-3">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-slate-900 text-white shadow-sm">
              <FileCheck2 className="h-5 w-5" aria-hidden="true" />
            </div>
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="font-semibold text-slate-950">Final Payroll Record</h3>
                {record && (
                  <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${
                    complete ? 'bg-emerald-100 text-emerald-800' : attention ? 'bg-amber-100 text-amber-800' : 'bg-blue-100 text-blue-800'
                  }`}>
                    {humanize(record.completion.status)}
                  </span>
                )}
              </div>
              <p className="mt-1 max-w-2xl text-sm text-slate-600">
                One Cornerstone-native record tying approved payroll to its balanced journal, employee payments, liabilities, YTD continuity, and source evidence.
              </p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)} disabled={!record || loading}>
              {loading ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" aria-hidden="true" /> : <Eye className="mr-1.5 h-4 w-4" aria-hidden="true" />}
              {loading ? 'Loading' : 'View record'}
            </Button>
            <ReportDownloadMenu
              disabled={!record}
              ariaLabel="Export final payroll record"
              formats={[
                { key: 'xlsx', label: 'Excel workbook (.xlsx)', description: 'Accountant-ready record with separate supporting tabs.', kind: 'spreadsheet', loading: exporting === 'xlsx', onSelect: () => exportRecord('xlsx') },
                { key: 'pdf', label: 'PDF record (.pdf)', description: 'Read-only record for retention or sharing.', kind: 'pdf', loading: exporting === 'pdf', onSelect: () => exportRecord('pdf') },
              ]}
            />
          </div>
        </div>

        {error && <div role="alert" className="border-t border-red-200 bg-red-50 px-5 py-3 text-sm text-red-700">{error}</div>}

        {record && (
          <div className="grid grid-cols-2 border-t border-slate-200 md:grid-cols-4">
            <div className="border-b border-r border-slate-200 p-4 md:border-b-0">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Payroll</p>
              <div className="mt-1"><StatusMark good={record.official_payroll.status === 'official'} label={humanize(record.official_payroll.status)} /></div>
              <p className="mt-1 text-xs text-slate-500">{money(record.official_payroll.net_pay)} net</p>
            </div>
            <div className="border-b border-slate-200 p-4 md:border-b-0 md:border-r">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Journal</p>
              <div className="mt-1"><StatusMark good={record.journal.balanced} label={record.journal.balanced ? 'Balanced' : 'Out of balance'} /></div>
              <p className="mt-1 text-xs text-slate-500">{money(record.journal.debit_total)} total</p>
            </div>
            <div className="border-r border-slate-200 p-4">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Employee checks</p>
              <p className="mt-1 text-sm font-semibold text-slate-900">{record.employee_payments.reconciled_count} of {record.employee_payments.required_count} reconciled</p>
              <p className="mt-1 text-xs text-slate-500">{record.employee_payments.outstanding_count} checks open · {record.employee_payments.direct_deposit_count} direct deposit</p>
            </div>
            <div className="p-4">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">Liabilities</p>
              <p className="mt-1 text-sm font-semibold text-slate-900">{money(record.liabilities.paid_amount)} paid</p>
              <p className="mt-1 text-xs text-slate-500">{money(record.liabilities.outstanding_amount)} outstanding</p>
            </div>
          </div>
        )}
      </Card>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="dialog-wide dialog-top max-h-[90vh] overflow-y-auto">
          <div className="flex items-start justify-between gap-4">
            <DialogHeader>
              <DialogTitle>Final Payroll Record</DialogTitle>
              <DialogDescription>
                {record ? `${record.company.name} · ${record.pay_period.start_date} through ${record.pay_period.end_date} · paid ${record.pay_period.pay_date}` : 'Committed payroll record'}
              </DialogDescription>
            </DialogHeader>
            <Button type="button" variant="ghost" size="sm" className="h-9 w-9 p-0" onClick={() => setOpen(false)} aria-label="Close final payroll record">
              <X className="h-4 w-4" aria-hidden="true" />
            </Button>
          </div>

          {record && (
            <div className="space-y-6">
              {(record.completion.blockers.length > 0 || record.completion.open_items.length > 0) && (
                <section className={`rounded-xl border p-4 ${attention ? 'border-amber-200 bg-amber-50' : 'border-blue-200 bg-blue-50'}`} aria-labelledby="closeout-heading">
                  <h4 id="closeout-heading" className="font-semibold text-slate-950">{humanize(record.completion.status)}</h4>
                  {record.completion.blockers.length > 0 && (
                    <div className="mt-2"><p className="text-sm font-medium text-slate-800">Resolve before relying on this record:</p><ul className="mt-1 list-disc space-y-1 pl-5 text-sm text-slate-700">{record.completion.blockers.map(item => <li key={item}>{item}</li>)}</ul></div>
                  )}
                  {record.completion.open_items.length > 0 && (
                    <div className="mt-2"><p className="text-sm font-medium text-slate-800">Settlement still in progress:</p><ul className="mt-1 list-disc space-y-1 pl-5 text-sm text-slate-700">{record.completion.open_items.map(item => <li key={item}>{item}</li>)}</ul></div>
                  )}
                </section>
              )}

              <section aria-labelledby="payroll-totals-heading">
                <h4 id="payroll-totals-heading" className="font-semibold text-slate-950">Official payroll totals</h4>
                <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
                  {[
                    ['Gross pay', record.official_payroll.gross_pay], ['Deductions', record.official_payroll.employee_deductions],
                    ['Net pay', record.official_payroll.net_pay], ['Total payroll cost', record.official_payroll.total_payroll_cost],
                  ].map(([label, value]) => <div key={label} className="rounded-lg border border-slate-200 bg-slate-50 p-3"><p className="text-xs text-slate-500">{label}</p><p className="mt-1 font-mono text-sm font-semibold text-slate-950">{money(value)}</p></div>)}
                </div>
              </section>

              <section aria-labelledby="journal-heading">
                <div className="flex items-center justify-between gap-3"><h4 id="journal-heading" className="font-semibold text-slate-950">Balanced payroll journal</h4><StatusMark good={record.journal.balanced} label={record.journal.balanced ? 'Balanced' : `${money(record.journal.difference)} difference`} /></div>
                <p className="mt-1 text-xs text-slate-500">{record.journal.basis}</p>
                <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200">
                  <table className="w-full text-sm"><thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Reference category</th><th className="px-3 py-2 text-right">Debit</th><th className="px-3 py-2 text-right">Credit</th></tr></thead><tbody>{record.journal.lines.map(line => <tr key={line.account_key} className="border-t border-slate-100"><td className="px-3 py-2"><span className="font-medium text-slate-900">{line.account_label}</span><span className="block text-xs text-slate-500">{line.source}</span></td><td className="px-3 py-2 text-right font-mono">{Number(line.debit) ? money(line.debit) : '—'}</td><td className="px-3 py-2 text-right font-mono">{Number(line.credit) ? money(line.credit) : '—'}</td></tr>)}</tbody><tfoot className="border-t-2 border-slate-200 bg-slate-50 font-semibold"><tr><td className="px-3 py-2">Total</td><td className="px-3 py-2 text-right font-mono">{money(record.journal.debit_total)}</td><td className="px-3 py-2 text-right font-mono">{money(record.journal.credit_total)}</td></tr></tfoot></table>
                </div>
              </section>

              <div className="grid gap-6 lg:grid-cols-2">
                <section aria-labelledby="checks-heading"><h4 id="checks-heading" className="font-semibold text-slate-950">Employee payments</h4><div className="mt-3 space-y-2">{record.employee_payments.rows.map(row => <div key={row.payroll_item_id} className="flex items-center justify-between gap-3 rounded-lg border border-slate-200 p-3"><div className="min-w-0"><p className="truncate text-sm font-medium text-slate-900">{row.employee_name}</p><p className="text-xs text-slate-500">{row.payment_delivery_method === 'direct_deposit' ? (row.issuance_status === 'bank_confirmed' ? 'Direct deposit · bank payment confirmed' : 'Direct deposit · earnings stub ready') : `Check ${row.check_number || 'not assigned'} · ${humanize(row.issuance_status)}`}</p></div><div className="text-right"><p className="font-mono text-sm font-semibold">{money(row.amount)}</p><p className="text-xs text-slate-500">{row.payment_delivery_method === 'direct_deposit' ? (row.issuance_status === 'bank_confirmed' ? 'Bank evidence recorded' : 'Awaiting bank confirmation') : humanize(row.reconciliation_status)}</p></div></div>)}</div></section>
                <section aria-labelledby="liabilities-heading"><h4 id="liabilities-heading" className="font-semibold text-slate-950">Payroll liabilities</h4><div className="mt-3 space-y-2">{record.liabilities.obligations.length === 0 ? <p className="rounded-lg border border-dashed border-slate-300 p-4 text-sm text-slate-500">No active liability obligations are posted for this payroll.</p> : record.liabilities.obligations.map(row => <div key={row.key} className="rounded-lg border border-slate-200 p-3"><div className="flex justify-between gap-3"><p className="text-sm font-medium text-slate-900">{row.authority}</p><p className="font-mono text-sm font-semibold">{money(row.outstanding_amount)} open</p></div><p className="mt-1 text-xs text-slate-500">{money(row.paid_amount)} of {money(row.calculated_amount)} paid · {humanize(row.status)}</p></div>)}</div></section>
              </div>

              <section className="rounded-xl border border-slate-200 bg-slate-50 p-4" aria-labelledby="continuity-heading">
                <div className="flex flex-wrap items-center justify-between gap-2"><h4 id="continuity-heading" className="font-semibold text-slate-950">YTD continuity through {record.ytd_reconciliation.through_pay_date}</h4><StatusMark good={record.ytd_reconciliation.status === 'reconciled'} label={humanize(record.ytd_reconciliation.status)} /></div>
                <p className="mt-2 text-sm text-slate-600">Includes {record.ytd_reconciliation.cornerstone_payroll_count} Cornerstone payrolls and {record.ytd_reconciliation.quickbooks_paycheck_count} locked QuickBooks paychecks. YTD net pay: <span className="font-semibold text-slate-900">{money(record.ytd_reconciliation.totals.net_pay)}</span>.</p>
              </section>

              <section aria-labelledby="evidence-heading"><h4 id="evidence-heading" className="font-semibold text-slate-950">Approval and source evidence</h4><p className="mt-2 text-sm text-slate-600">{record.evidence.review ? `Approved review revision ${record.evidence.review.revision} · ${humanize(record.evidence.review.approval_method)} · ${record.evidence.review.approved_by_name || 'Approver retained'}` : record.evidence.client_approval_required ? 'The required client-approved review is not attached.' : `Client approval was not required${record.evidence.payroll_approval.approved_by_name ? ` · payroll approved by ${record.evidence.payroll_approval.approved_by_name}` : ''}.`}</p><p className="mt-1 text-xs text-slate-500">Record fingerprint: <span className="break-all font-mono">{record.record_fingerprint}</span></p></section>
            </div>
          )}

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>Close</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
