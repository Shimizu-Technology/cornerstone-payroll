import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Plus } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { employeePayrollFieldsApi, payrollFieldsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import { newPayItemDraft, payItemAmount, payItemGroups, payItemStatus, type PayItemDraft } from '@/lib/pay-items';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';
import { PayItemEditor } from './PayItemEditor';
import type { EmployeePayrollField, PayrollFieldDefinition, PayrollFieldKind } from '@/types';

interface Props {
  employeeId: number;
  companyId: number;
  employeeName: string;
  companyName: string;
  refreshVersion?: number;
  onPendingChange: (pending: boolean) => void;
  disabled?: boolean;
  existingRecurringItems?: Array<{ name: string; kind: 'addition' | 'deduction'; amount: number; treatment: string; active: boolean; notes?: string; onUpdateSetup?: () => void }>;
}

function readDraft(key: string): PayItemDraft | null {
  try {
    const raw = sessionStorage.getItem(key);
    if (!raw) return null;
    const value = JSON.parse(raw) as PayItemDraft;
    const strings = ['name', 'amount', 'startDate', 'endDate', 'notes', 'payee', 'reference'] as const;
    const ids = [value.assignmentId, value.fieldId];
    return value.dirty === true && payItemGroups.some((group) => group.kind === value.kind)
      && ['new', 'existing'].includes(value.source) && ['employee_only', 'client_wide'].includes(value.scope)
      && ['fixed', 'percentage', 'manual'].includes(value.amountType)
      && strings.every((key) => typeof value[key] === 'string')
      && typeof value.useDefault === 'boolean' && typeof value.active === 'boolean'
      && ids.every((id) => id === undefined || (Number.isSafeInteger(id) && id > 0)) ? value : null;
  } catch { return null; }
}

export function EmployeePayItemsPanel({ employeeId, companyId, employeeName, companyName, refreshVersion = 0, onPendingChange, disabled = false, existingRecurringItems = [] }: Props) {
  const { user, hasCapability } = useAuth();
  const canManageFields = hasCapability?.('manage_payroll_fields') === true;
  const draftKey = `pay-item-draft:v1:${user?.id ?? 0}:${companyId}:${employeeId}`;
  const [fields, setFields] = useState<PayrollFieldDefinition[]>([]);
  const [assignments, setAssignments] = useState<EmployeePayrollField[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [editor, setEditor] = useState<PayItemDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [busyRow, setBusyRow] = useState<number | null>(null);
  const [discard, setDiscard] = useState(false);
  const [recovered, setRecovered] = useState(false);
  const [showStopped, setShowStopped] = useState(false);
  const requestRef = useRef(0);
  const mutationRef = useRef(false);
  const scopeRef = useRef(`${companyId}:${employeeId}`);
  const restoredRef = useRef(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; requestRef.current += 1; onPendingChange(false); };
  }, [onPendingChange]);

  const load = useCallback(async () => {
    const request = ++requestRef.current;
    const scope = `${companyId}:${employeeId}`;
    scopeRef.current = scope;
    setLoading(true);
    try {
      const [definitions, rows] = await Promise.all([
        payrollFieldsApi.list({ employee_id: employeeId }, companyId),
        employeePayrollFieldsApi.list(employeeId, companyId, true),
      ]);
      if (!mountedRef.current || requestRef.current !== request || scopeRef.current !== scope) return;
      setFields(definitions.payroll_fields);
      setAssignments(rows.employee_payroll_fields);
      setLoadError(null);
      if (!restoredRef.current) {
        restoredRef.current = true;
        const draft = readDraft(draftKey);
        if (draft) { setEditor(draft); setRecovered(true); }
      }
    } catch (failure) {
      if (mountedRef.current && requestRef.current === request) setLoadError(failure instanceof Error ? failure.message : 'Could not load pay items.');
    } finally {
      if (mountedRef.current && requestRef.current === request) setLoading(false);
    }
  }, [companyId, employeeId, draftKey]);

  useEffect(() => { void load(); }, [load, refreshVersion]);
  useEffect(() => { onPendingChange(Boolean(editor) || saving || busyRow !== null); }, [editor, saving, busyRow, onPendingChange]);

  useEffect(() => {
    if (!editor?.dirty) return;
    try { sessionStorage.setItem(draftKey, JSON.stringify(editor)); } catch { /* The in-memory draft remains available. */ }
    const handleBeforeUnload = (event: BeforeUnloadEvent): void => { event.preventDefault(); event.returnValue = ''; };
    window.addEventListener('beforeunload', handleBeforeUnload);
    return () => window.removeEventListener('beforeunload', handleBeforeUnload);
  }, [editor, draftKey]);

  const clearDraft = (): void => {
    try { sessionStorage.removeItem(draftKey); } catch { /* Storage can be unavailable. */ }
    setEditor(null); setDiscard(false); setRecovered(false); setError(null);
  };
  const closeEditor = (): void => {
    if (mutationRef.current) return;
    if (editor?.dirty) setDiscard(true);
    else clearDraft();
  };
  const changeDraft = (patch: Partial<PayItemDraft>): void => {
    setEditor((current) => current ? { ...current, ...patch, ...(patch.name !== undefined ? { duplicateAcknowledged: false } : {}), dirty: true } : current);
    setError(null);
  };
  const fieldFor = (row: EmployeePayrollField): PayrollFieldDefinition =>
    fields.find((field) => field.id === row.payroll_field_definition_id) || { ...row.payroll_field, company_id: companyId, sort_order: 0 };
  const editingRow = editor?.assignmentId ? assignments.find((row) => row.id === editor.assignmentId) : undefined;
  const selectedField = editor?.fieldId ? fields.find((field) => field.id === editor.fieldId) || (editingRow ? fieldFor(editingRow) : undefined) : undefined;
  const availableFields = fields.filter((field) => field.active && !field.owner_employee_id && field.kind === editor?.kind && !assignments.some((row) => row.payroll_field_definition_id === field.id));
  const duplicateName = Boolean(editor && !editor.assignmentId && editor.name.trim() && [
    ...existingRecurringItems.filter((item) => item.active),
    ...assignments.filter((row) => row.active).map((row) => ({ name: fieldFor(row).name, kind: fieldFor(row).kind })),
  ].some((item) => item.kind === editor.kind && item.name.trim().toLocaleLowerCase() === editor.name.trim().toLocaleLowerCase()));

  const selectField = (id: number): void => {
    const field = fields.find((candidate) => candidate.id === id && candidate.active && !candidate.owner_employee_id);
    if (!field || field.kind !== editor?.kind) return;
    changeDraft({ fieldId: id, name: field.name, treatment: field.tax_treatment, category: field.category,
      reportingGroup: field.reporting_group || '', amountType: field.amount_type, useDefault: true,
      amount: '', payee: field.payee_name || '', reference: field.reference_number || '' });
  };
  const openNew = (kind: PayrollFieldKind): void => {
    setError(null); setSuccess(null); setRecovered(false);
    setEditor({ ...newPayItemDraft(kind), startDate: guamBusinessDate() });
  };
  const openEdit = (row: EmployeePayrollField): void => {
    const field = fieldFor(row);
    const value = field.amount_type === 'percentage' ? row.percentage : row.amount;
    setError(null); setSuccess(null); setRecovered(false);
    setEditor({ ...newPayItemDraft(field.kind), assignmentId: row.id, fieldId: field.id,
      source: field.owner_employee_id ? 'new' : 'existing', scope: field.owner_employee_id ? 'employee_only' : 'client_wide',
      name: field.name, treatment: field.tax_treatment, category: field.category, reportingGroup: field.reporting_group || '',
      amountType: field.amount_type, amount: value == null ? '' : String(value), useDefault: value == null,
      startDate: row.start_date || '', endDate: row.end_date || '', notes: row.notes || '',
      payee: field.payee_name || '', reference: field.reference_number || '', active: row.active });
  };
  const updateLocal = (row: EmployeePayrollField, field?: PayrollFieldDefinition): void => {
    setAssignments((current) => [...current.filter((candidate) => candidate.id !== row.id), row]);
    if (field) setFields((current) => [...current.filter((candidate) => candidate.id !== field.id), field]);
  };

  const save = async (): Promise<void> => {
    if (!editor || disabled || mutationRef.current) return;
    const draft = editor;
    const linked = Boolean(editingRow?.employee_loan_id);
    if (duplicateName && !draft.duplicateAcknowledged) { setError('Edit the existing item, or confirm that you intend to add a separate item.'); return; }
    if (!draft.name.trim() || (draft.source === 'existing' && !draft.fieldId)) { setError('Enter a name or choose an existing client field.'); return; }
    if (draft.startDate && draft.endDate && draft.endDate < draft.startDate) { setError('Last payday must be on or after first payday.'); return; }
    const numericValue = Number(draft.amount);
    if (!linked && draft.amountType !== 'manual' && !draft.useDefault && (!draft.amount.trim() || !Number.isFinite(numericValue) || numericValue < 0)) { setError('Enter a valid amount of zero or more.'); return; }
    const scope = `${companyId}:${employeeId}`;
    mutationRef.current = true; setSaving(true); setError(null);
    const assignment: Partial<EmployeePayrollField> = {
      start_date: draft.startDate || null, end_date: draft.endDate || null, notes: draft.notes.trim(), active: draft.active,
      ...(!linked && !(draft.assignmentId && draft.amountType === 'manual' && selectedField?.amount_type === 'manual') ? {
        amount: draft.amountType === 'fixed' && !draft.useDefault ? Math.round(numericValue * 100) / 100 : null,
        percentage: draft.amountType === 'percentage' && !draft.useDefault ? numericValue : null,
      } : {}),
    };
    const definition: Partial<PayrollFieldDefinition> = {
      name: draft.name.trim(), kind: draft.kind, tax_treatment: draft.treatment, category: draft.category,
      reporting_group: draft.reportingGroup || null,
      amount_type: draft.amountType, payee_name: draft.payee.trim(), reference_number: draft.reference.trim(),
      ...(!draft.assignmentId ? {
        default_amount: draft.scope === 'client_wide' && draft.amountType === 'fixed' ? assignment.amount ?? null : null,
        default_percentage: draft.scope === 'client_wide' && draft.amountType === 'percentage' ? assignment.percentage ?? null : null,
      } : {}),
    };
    try {
      if (draft.assignmentId) {
        const response = await employeePayrollFieldsApi.updatePayItem(employeeId, draft.assignmentId, assignment,
          draft.scope === 'employee_only' && !linked ? definition : undefined, companyId);
        if (!mountedRef.current || scopeRef.current !== scope) return;
        updateLocal(response.employee_payroll_field, response.payroll_field);
      } else if (draft.source === 'existing') {
        const response = await employeePayrollFieldsApi.create(employeeId, { ...assignment, payroll_field_definition_id: draft.fieldId }, companyId);
        if (!mountedRef.current || scopeRef.current !== scope) return;
        updateLocal(response.employee_payroll_field);
      } else {
        const response = await employeePayrollFieldsApi.createAndAssign(employeeId, draft.scope, definition, assignment, companyId);
        if (!mountedRef.current || scopeRef.current !== scope) return;
        updateLocal(response.employee_payroll_field, response.payroll_field);
      }
      clearDraft();
      setSuccess(`Saved ${draft.name.trim()} for ${employeeName}. Recalculate any unfinished payroll to include the saved setup.`);
    } catch (failure) {
      if (mountedRef.current && scopeRef.current === scope) setError(failure instanceof Error ? failure.message : 'Could not save this item. Your entries are kept; try again.');
    } finally {
      mutationRef.current = false;
      if (mountedRef.current && scopeRef.current === scope) setSaving(false);
    }
  };

  const toggleActive = async (row: EmployeePayrollField): Promise<void> => {
    if (disabled || mutationRef.current) return;
    const scope = `${companyId}:${employeeId}`;
    const field = fieldFor(row);
    mutationRef.current = true; setBusyRow(row.id); setError(null);
    try {
      if (row.active) {
        const response = await employeePayrollFieldsApi.archive(employeeId, row.id, companyId);
        if (!mountedRef.current || scopeRef.current !== scope) return;
        updateLocal(response.employee_payroll_field);
      } else {
        const response = await employeePayrollFieldsApi.updatePayItem(employeeId, row.id, { active: true },
          field.owner_employee_id && !row.employee_loan_id && !field.active ? { active: true } : undefined, companyId);
        if (!mountedRef.current || scopeRef.current !== scope) return;
        updateLocal(response.employee_payroll_field, response.payroll_field);
      }
      setSuccess(`${row.active ? 'Stopped' : 'Reactivated'} ${field.name} for ${employeeName}. Recalculate unfinished payroll to apply the change.`);
      if (row.active) setShowStopped(true);
    } catch (failure) {
      if (mountedRef.current && scopeRef.current === scope) setError(failure instanceof Error ? failure.message : 'Could not change this item.');
    } finally {
      mutationRef.current = false;
      if (mountedRef.current && scopeRef.current === scope) setBusyRow(null);
    }
  };

  const stoppedCount = assignments.filter((row) => !row.active || !fieldFor(row).active).length + existingRecurringItems.filter((item) => !item.active).length;
  return <Card id="employee-pay-items" className="mb-6 scroll-mt-28 border-neutral-200">
    <CardHeader><div className="flex flex-wrap items-start justify-between gap-3"><div><CardTitle>Additions and deductions</CardTitle><CardDescription>Manage this person’s recurring pay items. Each item saves here immediately.</CardDescription></div>
      {canManageFields && !disabled && <Link className="text-sm font-semibold text-primary-700 underline underline-offset-4" to={`/companies/${companyId}/payroll-fields`}>Client-wide payroll fields</Link>}
    </div></CardHeader>
    <CardContent className="space-y-4">
      {loading && <p role="status" className="text-sm text-neutral-600">Loading pay items…</p>}
      {loadError && <ActionFeedback tone="error" message={`Could not load pay setup. ${loadError}`}><Button type="button" variant="outline" size="sm" onClick={() => void load()}>Reload pay items</Button></ActionFeedback>}
      {success && <ActionFeedback tone="success" message={success} />}
      {error && !editor && <ActionFeedback tone="error" message={error} />}
      {payItemGroups.map((group) => {
        const rows = assignments.filter((row) => fieldFor(row).kind === group.kind && (showStopped || (row.active && fieldFor(row).active)));
        const existing = existingRecurringItems.filter((item) => item.kind === group.kind && (showStopped || item.active));
        return <section key={group.kind} aria-label={group.title} className={`rounded-2xl border p-4 ${group.className}`}>
          <div className="mb-4 flex flex-wrap items-start justify-between gap-3"><div><h3 className="text-base font-semibold text-neutral-950">{group.title} ({rows.length + existing.length})</h3><p className="mt-1 text-sm text-neutral-700">{group.description}</p></div>
            <Button type="button" variant="outline" size="sm" onClick={() => openNew(group.kind)} disabled={disabled || loading || Boolean(loadError) || saving || busyRow !== null}><Plus className="mr-1 h-4 w-4" />{group.action}</Button>
          </div>
          <div className="space-y-3">{rows.map((row) => {
            const field = fieldFor(row);
            const value = payItemAmount(row, field);
            const status = payItemStatus(row, field.active, guamBusinessDate());
            const inherited = field.amount_type === 'percentage' ? row.percentage == null : row.amount == null;
            return <div key={row.id} data-testid={`pay-item-${row.id}`} className="rounded-xl border border-neutral-200 bg-white p-4">
              <div className="flex flex-wrap items-start justify-between gap-3"><div className="min-w-0"><p className="break-words font-semibold text-neutral-950">{field.name}</p><div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-neutral-600"><span>{field.owner_employee_id ? 'Employee-specific' : 'Client-wide'}</span><span>{status}</span><span>{field.tax_treatment.replace(/_/g, ' ')}</span></div></div>
                <p className="font-semibold tabular-nums text-neutral-950">{row.employee_loan_id ? 'Managed in Loans' : value === null ? 'Enter each payroll' : field.amount_type === 'percentage' ? `${value}%` : formatCurrency(value)}</p>
              </div>
              {inherited && !row.employee_loan_id && field.amount_type !== 'manual' && <p className="mt-2 text-xs text-neutral-600">Uses client default</p>}
              <p className="mt-2 text-xs text-neutral-600">{row.start_date ? `From ${row.start_date}` : 'No start-date restriction'} · {row.end_date ? `through ${row.end_date}, inclusive` : 'until stopped'}</p>
              {row.notes && <p className="mt-2 break-words text-xs text-neutral-600">{row.notes}</p>}
              <div className="mt-3 flex flex-wrap gap-2"><Button type="button" variant="outline" size="sm" onClick={() => openEdit(row)} disabled={disabled || saving || busyRow !== null}>Edit</Button>
                <Button type="button" variant="ghost" size="sm" onClick={() => void toggleActive(row)} disabled={disabled || saving || busyRow !== null || (!row.active && !field.active && !field.owner_employee_id)}>{busyRow === row.id ? 'Saving…' : row.active ? 'Stop' : 'Reactivate'}</Button>
                {!field.owner_employee_id && canManageFields && !disabled && <Link to={`/companies/${companyId}/payroll-fields?field_id=${field.id}`} className="self-center text-xs font-semibold text-primary-700 underline underline-offset-4">Edit shared field</Link>}
              </div>
            </div>;
          })}{existing.map((item, index) => <div key={`${item.kind}:${item.name}:${index}`} className="rounded-xl border border-neutral-200 bg-white p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="font-semibold text-neutral-950">{item.name}</p><p className="mt-1 text-xs text-neutral-600">Employee-specific · {item.active ? 'Active' : 'Paused'} · {item.treatment.replace(/_/g, ' ')}</p></div><p className="font-semibold tabular-nums">{formatCurrency(item.amount)}</p></div><p className="mt-2 text-xs text-neutral-600">Existing recurring item. Update its setup to use editable amounts and payday controls.</p>{item.notes && <p className="mt-2 text-xs text-neutral-600">{item.notes} (reference only)</p>}{item.onUpdateSetup && <Button type="button" variant="outline" size="sm" className="mt-3" onClick={item.onUpdateSetup} disabled={disabled || saving || busyRow !== null}>Update setup</Button>}</div>)}{!loading && !loadError && rows.length + existing.length === 0 && <p className="rounded-xl border border-dashed border-neutral-300 bg-white/70 p-4 text-sm text-neutral-600">No {group.title.toLowerCase()} assigned. Use “{group.action}” to set one up.</p>}</div>
        </section>;
      })}
      {stoppedCount > 0 && <label className="flex items-center gap-2 text-sm text-neutral-700"><input type="checkbox" checked={showStopped} onChange={(event) => setShowStopped(event.target.checked)} />Show stopped items ({stoppedCount})</label>}
      <p className="text-xs text-neutral-600">Dates apply to the paycheck’s payday. Regular payroll includes these items; special runs include recurring setup only when selected.</p>
    </CardContent>
    {editor && <><PayItemEditor draft={editor} employeeName={employeeName} companyName={companyName} availableFields={availableFields} selectedField={selectedField}
      linkedLoan={Boolean(editingRow?.employee_loan_id)} duplicateName={duplicateName} saving={saving} error={error} onChange={changeDraft} onSelectField={selectField} onSave={() => void save()} onClose={closeEditor} />
      {recovered && <div data-feedback-portal role="status" className="fixed left-1/2 top-3 z-[130] w-[min(90vw,28rem)] -translate-x-1/2 rounded-xl bg-primary-950 p-3 text-sm text-white">Recovered your unfinished pay item for {employeeName}.</div>}
    </>}
    <Dialog open={discard} onOpenChange={setDiscard}><DialogContent className="dialog-center-mobile"><DialogTitle>Discard unfinished pay item?</DialogTitle><p className="mt-3 text-sm text-neutral-600">Your changes have not been saved. Keep editing or discard this draft.</p><div className="mt-5 flex flex-wrap justify-end gap-2"><Button type="button" variant="outline" onClick={() => setDiscard(false)}>Keep editing</Button><Button type="button" onClick={clearDraft}>Discard changes</Button></div></DialogContent></Dialog>
  </Card>;
}
