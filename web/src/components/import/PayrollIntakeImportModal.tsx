import { useMemo, useRef, useState, type ClipboardEvent } from 'react';
import { AlertTriangle, CheckCircle2, ClipboardList, FileText, UploadCloud } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Textarea } from '@/components/ui/textarea';
import { payrollIntakeImportsApi } from '@/services/api';
import type {
  PayrollIntakeApplyRowPayload,
  PayrollIntakeImportData,
  PayrollIntakeRowData,
} from '@/services/api';
import type { Employee, PayPeriod, PayrollItem } from '@/types';
import { formatCurrency } from '@/lib/utils';

interface PayrollIntakeImportModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  employees: Employee[];
  onImportComplete: (payPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => void;
}

type Step = 'upload' | 'preview' | 'applying' | 'done';
type EditableRow = PayrollIntakeRowData & { include: boolean };

const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const fullName = (employee: Employee) => `${employee.first_name} ${employee.last_name}`.trim();

function severityVariant(severity?: string) {
  if (severity === 'error') return 'danger' as const;
  if (severity === 'warning') return 'warning' as const;
  return 'info' as const;
}

function readinessBadge(row: EditableRow) {
  if (!row.include) return <Badge variant="outline">Skipped</Badge>;
  if (!row.employee_id) return <Badge variant="danger">Needs match</Badge>;
  if ((row.errors || []).length > 0 || (row.warnings || []).length > 0) return <Badge variant="warning">Review</Badge>;
  return <Badge variant="success">Ready</Badge>;
}

export function PayrollIntakeImportModal({
  open,
  onOpenChange,
  payPeriodId,
  employees,
  onImportComplete,
}: PayrollIntakeImportModalProps) {
  const [step, setStep] = useState<Step>('upload');
  const [pastedText, setPastedText] = useState('');
  const [files, setFiles] = useState<File[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [importData, setImportData] = useState<PayrollIntakeImportData | null>(null);
  const [rows, setRows] = useState<EditableRow[]>([]);
  const [acknowledgeWarnings, setAcknowledgeWarnings] = useState(false);
  const [forceOverwrite, setForceOverwrite] = useState(false);
  const [doneSummary, setDoneSummary] = useState<{ applied: number; skipped: number; errors: string[] } | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const employeeOptions = useMemo(() => (
    [...employees]
      .sort((a, b) => fullName(a).localeCompare(fullName(b)))
      .map((employee) => ({ value: String(employee.id), label: fullName(employee) }))
  ), [employees]);

  const totals = useMemo(() => rows.reduce((acc, row) => {
    if (!row.include) return acc;
    acc.regular += toNumber(row.regular_hours);
    acc.overtime += toNumber(row.overtime_hours);
    acc.tips += toNumber(row.reported_tips);
    return acc;
  }, { regular: 0, overtime: 0, tips: 0 }), [rows]);

  const includedRows = rows.filter((row) => row.include);
  const hasWarnings = includedRows.some((row) => (row.warnings || []).length > 0 || (row.errors || []).length > 0) || (importData?.warnings || []).length > 0;
  const hasBlockingMissingMatches = includedRows.some((row) => !row.employee_id);
  const canApply = includedRows.length > 0 && !hasBlockingMissingMatches && (!hasWarnings || acknowledgeWarnings);

  const reset = () => {
    setStep('upload');
    setPastedText('');
    setFiles([]);
    setLoading(false);
    setError(null);
    setImportData(null);
    setRows([]);
    setAcknowledgeWarnings(false);
    setForceOverwrite(false);
    setDoneSummary(null);
  };

  const handleClose = () => {
    reset();
    onOpenChange(false);
  };

  const addFiles = (nextFiles: FileList | File[]) => {
    const incoming = Array.from(nextFiles);
    setFiles((current) => {
      const existingKeys = new Set(current.map((file) => `${file.name}:${file.size}:${file.lastModified}`));
      return [...current, ...incoming.filter((file) => !existingKeys.has(`${file.name}:${file.size}:${file.lastModified}`))];
    });
  };

  const handlePaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    const pastedFiles = Array.from(event.clipboardData.files || []).filter((file) => file.type.startsWith('image/'));
    if (pastedFiles.length > 0) addFiles(pastedFiles);
  };

  const handlePreview = async () => {
    if (!pastedText.trim() && files.length === 0) return;

    try {
      setLoading(true);
      setError(null);
      const response = await payrollIntakeImportsApi.preview(payPeriodId, {
        source_type: 'spike_email',
        pasted_text: pastedText,
        files,
      });
      setImportData(response.import);
      setRows(response.import.rows.map((row) => ({ ...row, include: row.status !== 'skipped' })));
      setAcknowledgeWarnings(false);
      setStep('preview');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to preview payroll intake');
    } finally {
      setLoading(false);
    }
  };

  const updateRow = (rowId: number, patch: Partial<EditableRow>) => {
    setRows((current) => current.map((row) => (row.id === rowId ? normalizeRow({ ...row, ...patch }) : row)));
  };

  const normalizeRow = (row: EditableRow): EditableRow => {
    const paidOut = Math.max(0, toNumber(row.tips_paid_out));
    const reportedTips = Math.max(0, toNumber(row.reported_tips), paidOut);
    return { ...row, tips_paid_out: paidOut, reported_tips: reportedTips };
  };

  const buildApplyRows = (): PayrollIntakeApplyRowPayload[] => rows.map((row) => ({
    id: row.id,
    include: row.include,
    employee_id: row.employee_id,
    week1_hours: toNumber(row.week1_hours),
    week2_hours: toNumber(row.week2_hours),
    regular_hours: toNumber(row.regular_hours),
    overtime_hours: toNumber(row.overtime_hours),
    week1_tips: toNumber(row.week1_tips),
    week2_tips: toNumber(row.week2_tips),
    reported_tips: Math.max(toNumber(row.reported_tips), toNumber(row.tips_paid_out)),
    tips_paid_out: toNumber(row.tips_paid_out),
    loan_deduction: toNumber(row.loan_deduction),
    acknowledge_warnings: acknowledgeWarnings,
  }));

  const handleApply = async () => {
    if (!importData || !canApply) return;

    try {
      setStep('applying');
      setError(null);
      const response = await payrollIntakeImportsApi.apply(payPeriodId, importData.id, {
        rows: buildApplyRows(),
        acknowledge_warnings: acknowledgeWarnings,
        force_overwrite: forceOverwrite,
      });
      setDoneSummary({
        applied: response.results.applied.length,
        skipped: response.results.skipped.length,
        errors: response.results.errors.map((entry) => entry.error),
      });
      setImportData(response.import);
      setStep('done');
      onImportComplete(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply payroll intake');
      setStep('preview');
    }
  };

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (nextOpen ? onOpenChange(true) : handleClose())}>
      <DialogContent className="dialog-top dialog-wide max-w-7xl max-h-[calc(100vh-5rem)] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Spike Payroll Intake</DialogTitle>
          <DialogDescription>
            Paste the Spike payroll email or upload screenshots. Review every extracted row before applying taxable paid-out tips.
          </DialogDescription>
        </DialogHeader>

        {error && (
          <div className="rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
            {error}
          </div>
        )}

        {step === 'upload' && (
          <div className="grid gap-5 lg:grid-cols-[minmax(0,1.1fr)_360px]">
            <div className="space-y-4">
              <div>
                <label className="mb-2 block text-sm font-semibold text-neutral-800">Paste email body or copied table</label>
                <Textarea
                  value={pastedText}
                  onChange={(event) => setPastedText(event.target.value)}
                  onPaste={handlePaste}
                  placeholder="Paste the Spike email here. If you paste a screenshot from the clipboard, it will attach below."
                  className="min-h-[260px] rounded-2xl border-neutral-300 bg-white font-mono text-xs leading-6 shadow-sm"
                />
              </div>

              <div
                className="rounded-3xl border-2 border-dashed border-neutral-300 bg-neutral-50/70 p-6 text-center transition-colors hover:border-primary-300 hover:bg-primary-50/40"
                onDragOver={(event) => event.preventDefault()}
                onDrop={(event) => {
                  event.preventDefault();
                  addFiles(event.dataTransfer.files);
                }}
              >
                <UploadCloud className="mx-auto h-8 w-8 text-primary-700" aria-hidden="true" />
                <p className="mt-3 text-sm font-semibold text-neutral-900">Drop screenshots or PDFs here</p>
                <p className="mt-1 text-xs text-neutral-500">Images use the vision extractor only when pasted text is not enough.</p>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="image/*,.pdf"
                  multiple
                  className="hidden"
                  onChange={(event) => event.target.files && addFiles(event.target.files)}
                />
                <Button variant="outline" className="mt-4" onClick={() => fileInputRef.current?.click()}>
                  Select Files
                </Button>
              </div>
            </div>

            <div className="space-y-4">
              <Card className="rounded-3xl border border-neutral-200 bg-white p-5 shadow-sm">
                <div className="flex items-start gap-3">
                  <ClipboardList className="mt-0.5 h-5 w-5 text-primary-700" aria-hidden="true" />
                  <div>
                    <h3 className="font-semibold text-neutral-950">Spike tip policy</h3>
                    <p className="mt-2 text-sm leading-6 text-neutral-600">
                      Daily paid tips are imported as both reported taxable tips and tips paid out, so payroll taxes and W-2GU reporting stay correct without paying tips twice.
                    </p>
                  </div>
                </div>
              </Card>

              <Card className="rounded-3xl border border-neutral-200 bg-white p-5 shadow-sm">
                <div className="mb-3 flex items-center gap-2">
                  <FileText className="h-5 w-5 text-neutral-700" aria-hidden="true" />
                  <h3 className="font-semibold text-neutral-950">Attached source files</h3>
                </div>
                {files.length === 0 ? (
                  <p className="text-sm text-neutral-500">No screenshots or PDFs attached.</p>
                ) : (
                  <ul className="space-y-2 text-sm text-neutral-700">
                    {files.map((file) => (
                      <li key={`${file.name}:${file.size}:${file.lastModified}`} className="flex items-center justify-between gap-3 rounded-2xl bg-neutral-50 px-3 py-2">
                        <span className="truncate">{file.name}</span>
                        <button type="button" className="text-xs font-semibold text-danger-600 hover:text-danger-700" onClick={() => setFiles((current) => current.filter((candidate) => candidate !== file))}>
                          Remove
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </Card>
            </div>
          </div>
        )}

        {step === 'preview' && importData && (
          <div className="space-y-5">
            <div className="grid gap-3 sm:grid-cols-3">
              <SummaryCard label="Included rows" value={String(includedRows.length)} />
              <SummaryCard label="Hours" value={`${totals.regular.toFixed(2)} regular / ${totals.overtime.toFixed(2)} OT`} />
              <SummaryCard label="Paid-out tips" value={formatCurrency(totals.tips)} />
            </div>

            {(importData.warnings || []).length > 0 && (
              <div className="rounded-2xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-800">
                <p className="font-semibold">Import-level warnings</p>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {importData.warnings.map((warning, index) => <li key={`${warning.code}-${index}`}>{warning.message}</li>)}
                </ul>
              </div>
            )}

            <div className="overflow-x-auto rounded-3xl border border-neutral-200 bg-white shadow-sm">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-10">Use</TableHead>
                    <TableHead className="min-w-[220px]">Source / Employee</TableHead>
                    <TableHead className="text-right">W1 Hrs</TableHead>
                    <TableHead className="text-right">W2 Hrs</TableHead>
                    <TableHead className="text-right">Regular</TableHead>
                    <TableHead className="text-right">OT</TableHead>
                    <TableHead className="text-right">W1 Tips</TableHead>
                    <TableHead className="text-right">W2 Tips</TableHead>
                    <TableHead className="text-right">Reported Tips</TableHead>
                    <TableHead className="text-right">Tips Paid Out</TableHead>
                    <TableHead>Status</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => (
                    <TableRow key={row.id} className={!row.include ? 'opacity-50' : ''}>
                      <TableCell>
                        <input
                          type="checkbox"
                          className="rounded border-neutral-300"
                          checked={row.include}
                          onChange={(event) => updateRow(row.id, { include: event.target.checked })}
                        />
                      </TableCell>
                      <TableCell>
                        <div className="space-y-2">
                          <div>
                            <p className="font-semibold text-neutral-950">{row.source_employee_name}</p>
                            {row.match_confidence != null && (
                              <p className="text-xs text-neutral-500">Match confidence {Math.round(row.match_confidence * 100)}%</p>
                            )}
                          </div>
                          <Select
                            value={row.employee_id ? String(row.employee_id) : ''}
                            onChange={(event) => updateRow(row.id, { employee_id: event.target.value ? Number(event.target.value) : null })}
                            className="min-w-[210px]"
                          >
                            <option value="">Select employee</option>
                            {employeeOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                          </Select>
                          {[...(row.errors || []), ...(row.warnings || [])].map((warning, index) => (
                            <Badge key={`${warning.code}-${index}`} variant={severityVariant(warning.severity)} className="mr-1 whitespace-normal text-left">
                              {warning.message}
                            </Badge>
                          ))}
                        </div>
                      </TableCell>
                      <NumericCell value={row.week1_hours} onChange={(value) => updateRow(row.id, { week1_hours: value ?? 0 })} />
                      <NumericCell value={row.week2_hours} onChange={(value) => updateRow(row.id, { week2_hours: value ?? 0 })} />
                      <NumericCell value={row.regular_hours} onChange={(value) => updateRow(row.id, { regular_hours: value ?? 0 })} />
                      <NumericCell value={row.overtime_hours} onChange={(value) => updateRow(row.id, { overtime_hours: value ?? 0 })} />
                      <NumericCell value={row.week1_tips} onChange={(value) => updateRow(row.id, { week1_tips: value ?? 0 })} money />
                      <NumericCell value={row.week2_tips} onChange={(value) => updateRow(row.id, { week2_tips: value ?? 0 })} money />
                      <NumericCell value={row.reported_tips} onChange={(value) => updateRow(row.id, { reported_tips: value ?? 0 })} money />
                      <NumericCell value={row.tips_paid_out} onChange={(value) => updateRow(row.id, { tips_paid_out: value ?? 0 })} money />
                      <TableCell>{readinessBadge(row)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            {hasWarnings && (
              <label className="flex items-start gap-3 rounded-2xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-900">
                <input
                  type="checkbox"
                  checked={acknowledgeWarnings}
                  onChange={(event) => setAcknowledgeWarnings(event.target.checked)}
                  className="mt-0.5 rounded border-warning-300"
                />
                <span>I reviewed the highlighted warnings/errors and confirmed the rows are ready to apply.</span>
              </label>
            )}

            <label className="flex items-start gap-3 rounded-2xl border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-700">
              <input
                type="checkbox"
                checked={forceOverwrite}
                onChange={(event) => setForceOverwrite(event.target.checked)}
                className="mt-0.5 rounded border-neutral-300"
              />
              <span>Allow overwrite of existing manual/non-Spike payroll items for included employees.</span>
            </label>
          </div>
        )}

        {step === 'applying' && (
          <div className="flex flex-col items-center justify-center py-14 text-center">
            <div className="h-10 w-10 animate-spin rounded-full border-4 border-primary-100 border-t-primary-700" />
            <p className="mt-4 font-semibold text-neutral-900">Applying reviewed payroll intake...</p>
            <p className="mt-1 text-sm text-neutral-500">Calculating wages, taxes, and paid-out tip offsets.</p>
          </div>
        )}

        {step === 'done' && doneSummary && (
          <div className="space-y-4 py-4">
            <div className="flex items-start gap-3 rounded-3xl border border-success-200 bg-success-50 p-5 text-success-800">
              <CheckCircle2 className="mt-0.5 h-5 w-5" aria-hidden="true" />
              <div>
                <p className="font-semibold">Payroll intake applied</p>
                <p className="mt-1 text-sm">Applied {doneSummary.applied} row{doneSummary.applied === 1 ? '' : 's'} and skipped {doneSummary.skipped}.</p>
              </div>
            </div>
            {doneSummary.errors.length > 0 && (
              <div className="rounded-2xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
                {doneSummary.errors.join(', ')}
              </div>
            )}
          </div>
        )}

        <DialogFooter>
          {step === 'upload' && (
            <>
              <Button variant="outline" onClick={handleClose}>Cancel</Button>
              <Button onClick={handlePreview} disabled={loading || (!pastedText.trim() && files.length === 0)}>
                {loading ? 'Extracting...' : 'Preview Intake'}
              </Button>
            </>
          )}
          {step === 'preview' && (
            <>
              <Button variant="outline" onClick={() => setStep('upload')}>Back</Button>
              {!canApply && hasBlockingMissingMatches && (
                <span className="mr-auto flex items-center gap-2 text-sm text-danger-600">
                  <AlertTriangle className="h-4 w-4" aria-hidden="true" /> Match all included rows.
                </span>
              )}
              <Button onClick={handleApply} disabled={!canApply}>Apply Reviewed Rows</Button>
            </>
          )}
          {step === 'done' && <Button onClick={handleClose}>Close</Button>}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <Card className="rounded-3xl border border-neutral-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-semibold uppercase tracking-[0.18em] text-neutral-500">{label}</p>
      <p className="mt-2 text-lg font-semibold text-neutral-950">{value}</p>
    </Card>
  );
}

function NumericCell({ value, onChange, money = false }: { value: number; onChange: (value: number | null) => void; money?: boolean }) {
  return (
    <TableCell className="min-w-[96px] text-right">
      <NumericInput
        value={value}
        onValueChange={onChange}
        min={0}
        fixedDecimalsOnBlur={money ? 2 : 2}
        className="h-9 min-h-0 rounded-xl px-2 py-1 text-right text-xs"
      />
    </TableCell>
  );
}
