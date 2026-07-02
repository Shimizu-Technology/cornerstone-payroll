import { useEffect, useMemo, useRef, useState, type ClipboardEvent } from 'react';
import { AlertTriangle, CheckCircle2, ClipboardList, FileText, UploadCloud, UserPlus } from 'lucide-react';
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
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Textarea } from '@/components/ui/textarea';
import { employeesApi, payrollIntakeImportsApi } from '@/services/api';
import type {
  PayrollIntakeApplyRowPayload,
  PayrollIntakeImportData,
  PayrollIntakeRowData,
} from '@/services/api';
import type { Employee, EmployeeFormData, PayPeriod, PayrollItem } from '@/types';
import { formatCurrency } from '@/lib/utils';

interface PayrollIntakeImportModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  employees: Employee[];
  onEmployeeCreated?: (employee: Employee) => void;
  onImportComplete: (payPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => void;
}

type Step = 'upload' | 'preview' | 'applying' | 'done';
type EditableRow = PayrollIntakeRowData & { include: boolean };
type NewEmployeeForm = { first_name: string; last_name: string; pay_rate: string; hire_date: string };

const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const fullName = (employee: Employee) => `${employee.first_name} ${employee.last_name}`.trim();
const todayIso = () => new Date().toISOString().slice(0, 10);

const namePartsFromSource = (sourceName: string): Pick<NewEmployeeForm, 'first_name' | 'last_name'> => {
  const parts = sourceName.trim().split(/\s+/).filter(Boolean);
  if (parts.length <= 1) return { first_name: sourceName.trim(), last_name: '' };
  return { first_name: parts[0], last_name: parts.slice(1).join(' ') };
};

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
  onEmployeeCreated,
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
  const [localEmployees, setLocalEmployees] = useState<Employee[]>(employees);
  const [createEmployeeRow, setCreateEmployeeRow] = useState<EditableRow | null>(null);
  const [newEmployeeForm, setNewEmployeeForm] = useState<NewEmployeeForm>({ first_name: '', last_name: '', pay_rate: '', hire_date: todayIso() });
  const [creatingEmployee, setCreatingEmployee] = useState(false);
  const [createEmployeeError, setCreateEmployeeError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setLocalEmployees(employees);
  }, [employees]);

  const employeeOptions = useMemo(() => (
    [...localEmployees]
      .sort((a, b) => fullName(a).localeCompare(fullName(b)))
      .map((employee) => ({ value: String(employee.id), label: fullName(employee) }))
  ), [localEmployees]);

  const totals = useMemo(() => rows.reduce((acc, row) => {
    if (!row.include) return acc;
    acc.regular += toNumber(row.regular_hours);
    acc.overtime += toNumber(row.overtime_hours);
    acc.tips += toNumber(row.reported_tips);
    return acc;
  }, { regular: 0, overtime: 0, tips: 0 }), [rows]);

  const includedRows = rows.filter((row) => row.include);
  const duplicateEmployeeIds = useMemo(() => {
    const counts = new Map<number, number>();
    rows.forEach((row) => {
      if (!row.include || !row.employee_id) return;
      counts.set(row.employee_id, (counts.get(row.employee_id) || 0) + 1);
    });
    return new Set(Array.from(counts.entries()).filter(([, count]) => count > 1).map(([employeeId]) => employeeId));
  }, [rows]);
  const hasWarnings = includedRows.some((row) => (row.warnings || []).length > 0 || (row.errors || []).length > 0) || (importData?.warnings || []).length > 0;
  const hasBlockingMissingMatches = includedRows.some((row) => !row.employee_id);
  const hasDuplicateEmployeeMappings = duplicateEmployeeIds.size > 0;
  const canApply = includedRows.length > 0 && !hasBlockingMissingMatches && !hasDuplicateEmployeeMappings && (!hasWarnings || acknowledgeWarnings);

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
    setCreateEmployeeRow(null);
    setCreateEmployeeError(null);
    setCreatingEmployee(false);
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

  const updateWeekTips = (rowId: number, key: 'week1_tips' | 'week2_tips', value: number) => {
    setRows((current) => current.map((row) => {
      if (row.id !== rowId) return row;

      const next = { ...row, [key]: Math.max(0, value) };
      const totalTips = toNumber(next.week1_tips) + toNumber(next.week2_tips);
      return normalizeRow({ ...next, reported_tips: totalTips, tips_paid_out: totalTips });
    }));
  };

  const updatePaidOutTips = (rowId: number, value: number) => {
    const totalTips = Math.max(0, value);
    updateRow(rowId, { reported_tips: totalTips, tips_paid_out: totalTips });
  };

  const normalizeRow = (row: EditableRow): EditableRow => {
    const paidOut = Math.max(0, toNumber(row.tips_paid_out));
    const reportedTips = Math.max(0, toNumber(row.reported_tips), paidOut);
    const errors = row.employee_id
      ? (row.errors || []).filter((warning) => warning.code !== 'unmatched_employee')
      : row.errors;
    return { ...row, tips_paid_out: paidOut, reported_tips: reportedTips, errors };
  };

  const openCreateEmployee = (row: EditableRow) => {
    const parsedName = namePartsFromSource(row.source_employee_name);
    setCreateEmployeeRow(row);
    setNewEmployeeForm({ ...parsedName, pay_rate: '', hire_date: todayIso() });
    setCreateEmployeeError(null);
  };

  const handleCreateEmployee = async () => {
    if (!importData || !createEmployeeRow) return;

    const payRate = Number(newEmployeeForm.pay_rate);
    if (!newEmployeeForm.first_name.trim() || !newEmployeeForm.last_name.trim()) {
      setCreateEmployeeError('First and last name are required.');
      return;
    }
    if (!Number.isFinite(payRate) || payRate < 0) {
      setCreateEmployeeError('Enter a valid hourly rate.');
      return;
    }
    if (!newEmployeeForm.hire_date) {
      setCreateEmployeeError('Hire date is required.');
      return;
    }

    const payload: EmployeeFormData & { company_id: number } = {
      company_id: importData.company_id,
      first_name: newEmployeeForm.first_name.trim(),
      last_name: newEmployeeForm.last_name.trim(),
      hire_date: newEmployeeForm.hire_date,
      employment_type: 'hourly',
      salary_type: 'annual',
      pay_rate: payRate,
      pay_frequency: 'biweekly',
      filing_status: 'single',
      allowances: 0,
      additional_withholding: 0,
      w4_dependent_credit: 0,
      w4_step2_multiple_jobs: false,
      w4_step4a_other_income: 0,
      w4_step4b_deductions: 0,
      retirement_rate: 0,
      roth_retirement_rate: 0,
    };

    try {
      setCreatingEmployee(true);
      setCreateEmployeeError(null);
      const response = await employeesApi.create(payload);
      const employee = response.data;
      setLocalEmployees((current) => [...current.filter((candidate) => candidate.id !== employee.id), employee]);
      onEmployeeCreated?.(employee);
      updateRow(createEmployeeRow.id, { employee_id: employee.id });
      setCreateEmployeeRow(null);
    } catch (err) {
      setCreateEmployeeError(err instanceof Error ? err.message : 'Failed to create employee');
    } finally {
      setCreatingEmployee(false);
    }
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
    <>
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
                    <TableHead className="min-w-[130px] text-right">Hours</TableHead>
                    <TableHead className="min-w-[120px] text-right">OT</TableHead>
                    <TableHead className="min-w-[130px] text-right">W1 Tips</TableHead>
                    <TableHead className="min-w-[130px] text-right">W2 Tips</TableHead>
                    <TableHead className="min-w-[150px] text-right">Paid-Out Tips</TableHead>
                    <TableHead className="min-w-[100px]">Status</TableHead>
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
                          <div className="flex min-w-[320px] items-center gap-2">
                            <Select
                              value={row.employee_id ? String(row.employee_id) : ''}
                              onChange={(event) => updateRow(row.id, { employee_id: event.target.value ? Number(event.target.value) : null })}
                              className="min-w-[230px] flex-1"
                            >
                              <option value="">Select employee</option>
                              {employeeOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                            </Select>
                            <Button type="button" variant="outline" size="sm" className="shrink-0" onClick={() => openCreateEmployee(row)}>
                              <UserPlus className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />
                              New
                            </Button>
                          </div>
                          {[...(row.errors || []), ...(row.warnings || [])].map((warning, index) => (
                            <Badge key={`${warning.code}-${index}`} variant={severityVariant(warning.severity)} className="mr-1 whitespace-normal text-left">
                              {warning.message}
                            </Badge>
                          ))}
                        </div>
                      </TableCell>
                      <NumericCell value={row.regular_hours} onChange={(value) => updateRow(row.id, { regular_hours: value ?? 0 })} />
                      <NumericCell value={row.overtime_hours} onChange={(value) => updateRow(row.id, { overtime_hours: value ?? 0 })} />
                      <NumericCell value={row.week1_tips} onChange={(value) => updateWeekTips(row.id, 'week1_tips', value ?? 0)} money />
                      <NumericCell value={row.week2_tips} onChange={(value) => updateWeekTips(row.id, 'week2_tips', value ?? 0)} money />
                      <NumericCell value={row.tips_paid_out} onChange={(value) => updatePaidOutTips(row.id, value ?? 0)} money />
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
              {!canApply && (hasBlockingMissingMatches || hasDuplicateEmployeeMappings) && (
                <span className="mr-auto flex items-center gap-2 text-sm text-danger-600">
                  <AlertTriangle className="h-4 w-4" aria-hidden="true" />
                  {hasBlockingMissingMatches ? 'Match all included rows.' : 'Each included row must map to a different employee.'}
                </span>
              )}
              <Button onClick={handleApply} disabled={!canApply}>Apply Reviewed Rows</Button>
            </>
          )}
          {step === 'done' && <Button onClick={handleClose}>Close</Button>}
        </DialogFooter>
      </DialogContent>
      </Dialog>

      <Dialog open={Boolean(createEmployeeRow)} onOpenChange={(nextOpen) => !nextOpen && setCreateEmployeeRow(null)}>
        <DialogContent className="max-w-lg rounded-3xl">
          <DialogHeader>
            <DialogTitle>Create employee</DialogTitle>
            <DialogDescription>
              Add this Spike employee to Cornerstone, then the intake row will be mapped automatically.
            </DialogDescription>
          </DialogHeader>

          {createEmployeeError && (
            <div className="rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
              {createEmployeeError}
            </div>
          )}

          <div className="grid gap-4 sm:grid-cols-2">
            <Input
              label="First name"
              value={newEmployeeForm.first_name}
              onChange={(event) => setNewEmployeeForm((current) => ({ ...current, first_name: event.target.value }))}
            />
            <Input
              label="Last name"
              value={newEmployeeForm.last_name}
              onChange={(event) => setNewEmployeeForm((current) => ({ ...current, last_name: event.target.value }))}
            />
            <Input
              label="Hourly rate"
              type="number"
              min="0"
              step="0.01"
              value={newEmployeeForm.pay_rate}
              onChange={(event) => setNewEmployeeForm((current) => ({ ...current, pay_rate: event.target.value }))}
              helperText="Used immediately if you apply this intake."
            />
            <Input
              label="Hire date"
              type="date"
              value={newEmployeeForm.hire_date}
              onChange={(event) => setNewEmployeeForm((current) => ({ ...current, hire_date: event.target.value }))}
            />
          </div>

          <div className="rounded-2xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm leading-6 text-warning-900">
            New employees are created as active hourly W-2 employees with biweekly pay and single/0 withholding defaults. Finish their profile later if they need different tax settings.
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setCreateEmployeeRow(null)} disabled={creatingEmployee}>Cancel</Button>
            <Button type="button" onClick={handleCreateEmployee} disabled={creatingEmployee}>
              {creatingEmployee ? 'Creating...' : 'Create and map employee'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
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
    <TableCell className="min-w-[124px] text-right">
      <NumericInput
        value={value}
        onValueChange={onChange}
        min={0}
        fixedDecimalsOnBlur={money ? 2 : 2}
        className="h-11 min-h-0 rounded-2xl px-3 py-2 text-right text-sm tabular-nums"
      />
    </TableCell>
  );
}
