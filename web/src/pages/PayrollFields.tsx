import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { payrollFieldsApi } from '@/services/api';
import type { PayrollFieldAmountType, PayrollFieldCategory, PayrollFieldDefinition, PayrollFieldKind, PayrollFieldReportingGroup, PayrollFieldTaxTreatment } from '@/types';

const kindOptions: Array<{ value: PayrollFieldKind; label: string; description: string }> = [
  { value: 'addition', label: 'Addition', description: 'Adds pay to the employee check.' },
  { value: 'deduction', label: 'Deduction', description: 'Subtracts from employee pay.' },
  { value: 'employer_contribution', label: 'Employer Contribution', description: 'Company-paid benefit or match.' },
];

const categoryOptions: PayrollFieldCategory[] = ['loan', 'retirement', 'insurance', 'rent', 'allotment', 'reimbursement', 'garnishment', 'child_support', 'phone', 'benefit', 'other'];
const amountTypeOptions: PayrollFieldAmountType[] = ['fixed', 'percentage', 'manual'];
const reportingGroupOptions: Array<{ value: '' | PayrollFieldReportingGroup; label: string; helper: string }> = [
  { value: '', label: 'No special report group', helper: 'Shows by its field name/category only.' },
  { value: '401k_pre_tax', label: '401(k) Pre-Tax', helper: 'Traditional 401(k) deduction or match.' },
  { value: '401k_after_tax', label: 'Roth 401(k)', helper: 'Designated Roth elective deferrals or an explicitly supported employer Roth contribution.' },
  { value: '401k_non_roth_after_tax', label: '401(k) non-Roth after-tax', helper: 'Voluntary after-tax contributions. These do not count as Roth catch-up.' },
  { value: 'retirement_other', label: 'Other Retirement', helper: 'Retirement-related, but not a 401(k) bucket.' },
];

const treatmentOptionsForKind = (kind: PayrollFieldKind): Array<{ value: PayrollFieldTaxTreatment; label: string }> => {
  if (kind === 'addition') {
    return [
      { value: 'taxable_addition', label: 'Taxable addition' },
      { value: 'non_taxable_addition', label: 'Non-taxable reimbursement/addition' },
    ];
  }
  if (kind === 'deduction') {
    return [
      { value: 'pre_tax_deduction', label: 'Pre-tax deduction' },
      { value: 'post_tax_deduction', label: 'Post-tax deduction' },
    ];
  }
  return [{ value: 'employer_contribution', label: 'Employer contribution' }];
};

const defaultField: Partial<PayrollFieldDefinition> = {
  name: '',
  kind: 'deduction',
  tax_treatment: 'post_tax_deduction',
  category: 'other',
  reporting_group: null,
  amount_type: 'fixed',
  default_amount: null,
  default_percentage: null,
  show_in_payroll_grid: true,
  active: true,
  sort_order: 0,
};

function ClientPayrollFields({ companyId, companyName, selectedFieldId }: { companyId: number; companyName: string; selectedFieldId: number | null }) {
  const [fields, setFields] = useState<PayrollFieldDefinition[]>([]);
  const { user } = useAuth();
  const draftKey = `shared-pay-field-draft:v1:${user?.id ?? 0}:${companyId}`;
  const [draft, setDraftState] = useState<Partial<PayrollFieldDefinition>>(defaultField);
  const [dirty, setDirty] = useState(false);
  const [recovered, setRecovered] = useState(false);
  const [deferredFieldId, setDeferredFieldId] = useState<number | null>(null);
  const restoredRef = useRef(false);
  const dirtyRef = useRef(false);
  const editingRef = useRef<number | null>(null);
  const setDraft = (update: Partial<PayrollFieldDefinition> | ((current: Partial<PayrollFieldDefinition>) => Partial<PayrollFieldDefinition>)) => { dirtyRef.current = true; setDraftState(update); setDirty(true); };
  const [editingId, setEditingId] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [impact, setImpact] = useState<{ kind: 'save' | 'archive' | 'reactivate'; field: PayrollFieldDefinition; payload?: Partial<PayrollFieldDefinition> } | null>(null);
  const mountedRef = useRef(true);
  const requestRef = useRef(0);
  const savingRef = useRef(false);
  const selectedRef = useRef<number | null>(null);
  const editorHeadingRef = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; requestRef.current += 1; };
  }, []);

  const loadFields = useCallback(async () => {
    const request = ++requestRef.current;
    setLoading(true);
    try {
      const res = await payrollFieldsApi.list(undefined, companyId);
      if (!mountedRef.current || requestRef.current !== request) return;
      setFields(res.payroll_fields);
      setError(null);
      if (!restoredRef.current) {
        restoredRef.current = true;
        try {
          const raw = sessionStorage.getItem(draftKey);
          const stored = raw ? JSON.parse(raw) as { draft?: Partial<PayrollFieldDefinition>; editingId?: number | null } | null : null;
          const validId = stored?.editingId == null || (Number.isSafeInteger(stored.editingId) && stored.editingId > 0 && res.payroll_fields.some((field) => field.id === stored.editingId));
          if (stored?.draft && typeof stored.draft.name === 'string' && kindOptions.some((kind) => kind.value === stored.draft?.kind)
            && categoryOptions.includes(stored.draft.category as PayrollFieldCategory) && amountTypeOptions.includes(stored.draft.amount_type as PayrollFieldAmountType)
            && treatmentOptionsForKind(stored.draft.kind!).some((option) => option.value === stored.draft?.tax_treatment) && validId) {
            dirtyRef.current = true; editingRef.current = stored.editingId ?? null;
            setDraftState(stored.draft); setEditingId(stored.editingId ?? null); setDirty(true); setRecovered(true);
            if (selectedFieldId && selectedFieldId !== editingRef.current) setDeferredFieldId(selectedFieldId);
            else if (selectedFieldId) selectedRef.current = selectedFieldId;
            return;
          }
          if (raw !== null) sessionStorage.removeItem(draftKey);
        } catch {
          try { sessionStorage.removeItem(draftKey); } catch { /* Storage can be unavailable. */ }
        }
      }
      if (selectedFieldId && selectedRef.current !== selectedFieldId) {
        const field = res.payroll_fields.find((candidate) => candidate.id === selectedFieldId);
        if (dirtyRef.current && editingRef.current !== selectedFieldId) setDeferredFieldId(selectedFieldId);
        else if (field) { selectedRef.current = selectedFieldId; editingRef.current = field.id; setEditingId(field.id); setDraftState(field); }
        else { selectedRef.current = selectedFieldId; setError('The requested client-wide field is no longer available. Choose a field below.'); }
      } else if (!selectedFieldId) {
        setDeferredFieldId(null);
      }
    } catch (err) {
      if (mountedRef.current && requestRef.current === request) setError(err instanceof Error ? err.message : 'Failed to load payroll fields');
    } finally {
      if (mountedRef.current && requestRef.current === request) setLoading(false);
    }
  }, [companyId, draftKey, selectedFieldId, setError]);

  useEffect(() => {
    void loadFields();
  }, [loadFields]);

  useEffect(() => {
    if (!dirty) return;
    try { sessionStorage.setItem(draftKey, JSON.stringify({ draft, editingId })); } catch { /* Keep the in-memory draft. */ }
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ''; };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [dirty, draft, editingId, draftKey]);

  const setKind = (kind: PayrollFieldKind) => {
    setDraft((prev) => ({
      ...prev,
      kind,
      tax_treatment: treatmentOptionsForKind(kind)[0].value,
    }));
  };

  const resetDraft = (reloadDeferred = true) => {
    dirtyRef.current = false; editingRef.current = null;
    setDraftState(defaultField);
    setEditingId(null); setDirty(false); setRecovered(false);
    if (deferredFieldId) { selectedRef.current = null; setDeferredFieldId(null); if (reloadDeferred) void loadFields(); }
    try { sessionStorage.removeItem(draftKey); } catch { /* Storage can be unavailable. */ }
  };

  const persistField = async (payload: Partial<PayrollFieldDefinition>, fieldId: number | null) => {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    try {
      if (fieldId) await payrollFieldsApi.update(fieldId, payload, companyId);
      else await payrollFieldsApi.create(payload, companyId);
      if (!mountedRef.current) return;
      resetDraft(false); setImpact(null);
      setSuccess(fieldId ? 'Shared field saved. Recalculate affected unfinished payrolls before finalizing.' : 'Client-wide field created. Assign it on each person’s profile to include it in their pay.');
      await loadFields();
    } catch (err) {
      if (mountedRef.current) setError(err instanceof Error ? err.message : 'Failed to save payroll field');
    } finally {
      savingRef.current = false;
      if (mountedRef.current) setSaving(false);
    }
  };

  const saveField = async () => {
    if (savingRef.current) return;
    setError(null);
    if (!draft.name?.trim()) {
      setError('Name is required');
      return;
    }
    const rawValue = draft.amount_type === 'percentage' ? draft.default_percentage : draft.default_amount;
    if (rawValue != null && (!Number.isFinite(rawValue) || rawValue < 0)) { setError('Enter a valid default of zero or more, or leave it blank.'); return; }
    const payload: Partial<PayrollFieldDefinition> = {
        name: draft.name.trim(), description: draft.description,
        kind: draft.kind, tax_treatment: draft.tax_treatment, category: draft.category,
        amount_type: draft.amount_type, active: draft.active, sort_order: draft.sort_order,
        show_in_payroll_grid: draft.show_in_payroll_grid,
        payee_name: draft.payee_name, reference_number: draft.reference_number,
        reporting_group: draft.reporting_group || null,
        default_amount: draft.amount_type === 'fixed' || draft.amount_type === 'manual' ? draft.default_amount ?? null : null,
        default_percentage: draft.amount_type === 'percentage' || draft.amount_type === 'manual' ? draft.default_percentage ?? null : null,
      };
    const field = fields.find((candidate) => candidate.id === editingId);
    if (field && (field.assigned_employee_count ?? 0) > 0) {
      setImpact({ kind: 'save', field, payload });
      return;
    }
    await persistField(payload, editingId);
  };

  const editField = (field: PayrollFieldDefinition) => {
    if (dirty) { setError('Save or discard your current field changes before editing another field.'); return; }
    editingRef.current = field.id;
    setEditingId(field.id);
    setDraftState(field);
    setSuccess(null);
    editorHeadingRef.current?.scrollIntoView?.({ block: 'start' });
    editorHeadingRef.current?.focus({ preventScroll: true });
  };

  const changeFieldStatus = async (field: PayrollFieldDefinition) => {
    if (savingRef.current) return;
    if (dirty) { setError('Save or discard your current field changes before changing another field.'); return; }
    setError(null);
    savingRef.current = true; setSaving(true);
    try {
      if (field.active) await payrollFieldsApi.archive(field.id, companyId);
      else await payrollFieldsApi.update(field.id, { active: true }, companyId);
      if (!mountedRef.current) return;
      if (editingId === field.id) {
        resetDraft(false);
      }
      await loadFields();
      setImpact(null);
      setSuccess(`${field.name} ${field.active ? 'archived' : 'reactivated'}. Recalculate affected unfinished payrolls before finalizing.`);
    } catch (err) {
      if (mountedRef.current) setError(err instanceof Error ? err.message : 'Failed to change payroll field');
    } finally {
      savingRef.current = false;
      if (mountedRef.current) setSaving(false);
    }
  };

  return (
    <div>
      <Header
        title="Client-wide payroll fields"
        description={`Reusable additions, deductions, and employer contributions for ${companyName}.`}
      />

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}
        {success && <ActionFeedback tone="success" message={success} />}
        {recovered && <ActionFeedback tone="info" message={`Recovered your unfinished client-wide field for ${companyName}.`} />}
        {deferredFieldId && <p role="status" className="rounded-xl border border-primary-100 bg-primary-50 p-4 text-sm text-primary-950">Your requested field, {fields.find((field) => field.id === deferredFieldId)?.name || `#${deferredFieldId}`}, was not opened because you have unfinished changes. Save or discard this draft to open it.</p>}
        <p className="rounded-xl border border-primary-100 bg-primary-50 p-4 text-sm text-primary-950">Client-wide means available to assign. Creating a field here does not add it to everyone’s pay. <Link className="font-semibold underline" to={`/companies/${companyId}/employees`}>Open a person’s profile</Link> to assign it or create an employee-specific item.</p>

        <Card>
          <CardContent className="space-y-4 py-5">
            <div>
              <h2 ref={editorHeadingRef} tabIndex={-1} className="scroll-mt-24 text-lg font-semibold text-gray-900">{editingId ? 'Edit client-wide field' : 'Create client-wide field'}</h2>
              <p className="mt-1 text-sm text-gray-500">Define the payroll behavior once, then assign it to employees who need it.</p>
            </div>

            <div className="grid gap-4 lg:grid-cols-4">
              <div className="lg:col-span-2">
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Name</label>
                <Input aria-label="Name" value={draft.name || ''} onChange={(e) => setDraft((prev) => ({ ...prev, name: e.target.value }))} placeholder="Auto Loan, 401(k), Rent" />
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Type</label>
                <Select aria-label="Type" value={draft.kind || 'deduction'} onChange={(e) => setKind(e.target.value as PayrollFieldKind)}>
                  {kindOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Tax treatment</label>
                <Select aria-label="Tax treatment" value={draft.tax_treatment || 'post_tax_deduction'} onChange={(e) => setDraft((prev) => ({ ...prev, tax_treatment: e.target.value as PayrollFieldTaxTreatment }))}>
                  {treatmentOptionsForKind(draft.kind || 'deduction').map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Category</label>
                <Select aria-label="Category" value={draft.category || 'other'} onChange={(e) => setDraft((prev) => ({ ...prev, category: e.target.value as PayrollFieldCategory }))}>
                  {categoryOptions.map((category) => <option key={category} value={category}>{category.replace(/_/g, ' ')}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Report group</label>
                <Select aria-label="Report group" value={draft.reporting_group || ''} onChange={(e) => setDraft((prev) => ({ ...prev, reporting_group: e.target.value ? e.target.value as PayrollFieldReportingGroup : null }))}>
                  {reportingGroupOptions.map((option) => <option key={option.value || 'none'} value={option.value}>{option.label}</option>)}
                </Select>
                <p className="mt-1 text-xs text-gray-500">
                  {reportingGroupOptions.find((option) => option.value === (draft.reporting_group || ''))?.helper}
                </p>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default</label>
                <Select aria-label="Amount type" value={draft.amount_type || 'fixed'} onChange={(e) => setDraft((prev) => ({ ...prev, amount_type: e.target.value as PayrollFieldAmountType, ...(e.target.value === 'manual' && prev.amount_type !== 'manual' ? { default_amount: null, default_percentage: null } : {}) }))}>
                  {amountTypeOptions.map((type) => <option key={type} value={type}>{type}</option>)}
                </Select>
              </div>
              {draft.category === 'retirement' && <p className="rounded-xl bg-primary-50 p-3 text-sm leading-6 text-primary-900 sm:col-span-2">Enable catch-up in Employee → Pay setup → Retirement plan. A new field adds another contribution; it does not reclassify an existing deduction or increase the annual limit.</p>}
              {draft.amount_type === 'percentage' ? (
                <div>
                  <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default %</label>
                  <Input aria-label="Default percentage" type="number" min="0" step="0.0001" value={draft.default_percentage ?? ''} onChange={(e) => setDraft((prev) => ({ ...prev, default_percentage: e.target.value === '' ? null : Number(e.target.value) }))} />
                </div>
              ) : draft.amount_type === 'fixed' ? (
                <div>
                  <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default amount</label>
                  <Input aria-label="Default amount" type="number" min="0" step="0.01" value={draft.default_amount ?? ''} onChange={(e) => setDraft((prev) => ({ ...prev, default_amount: e.target.value === '' ? null : Number(e.target.value) }))} /><p className="mt-1 text-xs text-neutral-500">Optional. Leave blank to enter amounts for each person.</p>
                </div>
              ) : null}
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Payroll review</label>
                <label className="mt-3 flex items-center gap-2 text-sm text-gray-700">
                  <input type="checkbox" checked={draft.show_in_payroll_grid !== false} onChange={(e) => setDraft((prev) => ({ ...prev, show_in_payroll_grid: e.target.checked }))} />
                  Show as payroll column
                </label>
              </div>
            </div>

            <details className="rounded-xl border border-neutral-200 p-3"><summary className="cursor-pointer text-sm font-semibold">More options</summary><div className="mt-4 grid gap-4 sm:grid-cols-2">
              <label className="text-sm font-medium">Description<Input aria-label="Description" className="mt-1" value={draft.description || ''} onChange={(event) => setDraft((current) => ({ ...current, description: event.target.value }))} /></label>
              {draft.kind !== 'addition' && <><label className="text-sm font-medium">Payee<Input aria-label="Payee" className="mt-1" value={draft.payee_name || ''} onChange={(event) => setDraft((current) => ({ ...current, payee_name: event.target.value }))} /></label><label className="text-sm font-medium">Reference number<Input aria-label="Reference number" className="mt-1" value={draft.reference_number || ''} onChange={(event) => setDraft((current) => ({ ...current, reference_number: event.target.value }))} /></label></>}
            </div></details>
            <p className="text-xs text-neutral-600">Hiding a payroll column does not stop an item from calculating. Archive the field or stop a person’s assignment to suspend its automatic use.</p>
            <div className="grid gap-2 sm:flex [&>button]:w-full sm:[&>button]:w-auto">
              <Button onClick={() => void saveField()} disabled={saving || loading}>{saving ? 'Saving…' : editingId ? 'Save changes' : 'Create field'}</Button>
              {(editingId || dirty) && <Button variant="outline" onClick={() => resetDraft()} disabled={saving}>{dirty ? 'Discard changes' : 'Cancel'}</Button>}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardContent className="py-0">
            {loading ? (
              <div className="py-8 text-center text-sm text-gray-500">Loading payroll fields…</div>
            ) : fields.length === 0 ? (
              <div className="py-8 text-center text-sm text-gray-500">No payroll fields yet.</div>
            ) : (
              <>
                <div className="space-y-3 py-4 sm:hidden">
                  {fields.map((field) => (
                    <MobileRecordCard key={field.id}><div data-testid={`shared-field-mobile-${field.id}`}>
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-neutral-950">{field.name}</p>
                          <p className="mt-1 text-sm capitalize text-neutral-500">Client-wide · {field.kind.replace(/_/g, ' ')}</p><p className="mt-1 text-xs text-neutral-500">Used by {field.assigned_employee_count ?? 0} people</p>
                        </div>
                        <span className={field.active ? 'text-sm font-medium text-green-700' : 'text-sm text-neutral-500'}>{field.active ? 'Active' : 'Archived'}</span>
                      </div>
                      <div className="mt-4 grid grid-cols-2 gap-3">
                        <MobileField label="Treatment" value={<span className="capitalize">{field.tax_treatment.replace(/_/g, ' ')}</span>} />
                        <MobileField label="Category" value={<span className="capitalize">{field.category.replace(/_/g, ' ')}</span>} />
                        <MobileField label="Report group" value={field.reporting_group ? reportingGroupOptions.find((option) => option.value === field.reporting_group)?.label || field.reporting_group : 'None'} />
                        <MobileField label="Default" value={field.amount_type === 'percentage' ? (field.default_percentage == null ? 'Per person' : `${field.default_percentage}%`) : field.amount_type === 'fixed' ? (field.default_amount == null ? 'Per person' : `$${Number(field.default_amount).toFixed(2)}`) : 'Manual'} />
                        <MobileField label="Payroll review" value={field.show_in_payroll_grid === false ? 'Hidden' : 'Shown'} />
                      </div>
                      <MobileCardActions>
                        <Button variant="outline" size="sm" onClick={() => editField(field)} disabled={saving}>Edit</Button>
                        <Button variant="ghost" size="sm" disabled={saving} onClick={() => setImpact({ kind: field.active ? 'archive' : 'reactivate', field })}>{field.active ? 'Archive' : 'Reactivate'}</Button>
                      </MobileCardActions>
                    </div></MobileRecordCard>
                  ))}
                </div>
                <div className="hidden overflow-x-auto sm:block">
                  <table className="min-w-[68rem] w-full text-sm">
                  <thead className="border-b bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                    <tr>
                      <th className="px-4 py-3 text-left">Name</th>
                      <th className="px-4 py-3 text-left">Type</th>
                      <th className="px-4 py-3 text-left">Treatment</th>
                      <th className="px-4 py-3 text-left">Category</th>
                      <th className="px-4 py-3 text-left">Report group</th>
                      <th className="px-4 py-3 text-right">Default</th>
                      <th className="px-4 py-3 text-left">Status</th>
                      <th className="px-4 py-3 text-right">Actions</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y">
                    {fields.map((field) => (
                      <tr key={field.id} data-testid={`shared-field-${field.id}`}>
                        <td className="px-4 py-3 font-medium text-gray-900">{field.name}<p className="mt-1 text-xs font-normal text-neutral-500">Client-wide · Used by {field.assigned_employee_count ?? 0} people</p></td>
                        <td className="px-4 py-3 capitalize">{field.kind.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3 capitalize">{field.tax_treatment.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3 capitalize">{field.category.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3">{field.reporting_group ? reportingGroupOptions.find((option) => option.value === field.reporting_group)?.label || field.reporting_group : '—'}</td>
                        <td className="px-4 py-3 text-right font-mono">
                          {field.amount_type === 'percentage' ? (field.default_percentage == null ? 'Per person' : `${field.default_percentage}%`) : field.amount_type === 'fixed' ? (field.default_amount == null ? 'Per person' : `$${Number(field.default_amount).toFixed(2)}`) : 'Manual'}
                        </td>
                        <td className="px-4 py-3">{field.active ? 'Active' : 'Archived'}</td>
                        <td className="px-4 py-3 text-right">
                          <Button variant="ghost" size="sm" onClick={() => editField(field)} disabled={saving}>Edit</Button>
                          <Button variant="ghost" size="sm" disabled={saving} onClick={() => setImpact({ kind: field.active ? 'archive' : 'reactivate', field })}>{field.active ? 'Archive' : 'Reactivate'}</Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                  </table>
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>
      <Dialog open={Boolean(impact)} onOpenChange={(open) => { if (!open && !saving) { setImpact(null); setError(null); } }} dismissOnEscape={!saving}>
        <DialogContent className="dialog-center-mobile"><DialogTitle>Review shared field changes</DialogTitle>
          {impact && <><p className="mt-3 text-sm font-semibold">{impact.field.name} · {companyName}</p><p className="mt-2 text-sm text-neutral-700">Used by {impact.field.assigned_employee_count ?? 0} people, with {impact.field.active_assignment_count ?? 0} active assignments.</p>
          <p className="mt-3 text-sm text-neutral-700">{impact.kind === 'save' ? 'Shared name, tax treatment and calculation settings affect everyone using this field. Default amounts affect only people who use the client default; their own amounts stay separate.' : impact.kind === 'archive' ? 'Archiving stops automatic use of this field for assigned people. Their saved payroll history stays intact.' : 'Reactivating makes this field available again to its active assignments, within their payday dates.'}</p>
          <p className="mt-3 text-sm text-neutral-600">Affected unfinished payrolls must be recalculated before approval. Finalized paychecks stay unchanged.</p>
          {error && <ActionFeedback tone="error" message={error} />}
          <div className="mt-5 flex flex-wrap justify-end gap-2"><Button variant="outline" disabled={saving} onClick={() => { setImpact(null); setError(null); }}>Cancel</Button><Button disabled={saving} onClick={() => { if (impact.kind === 'save' && impact.payload) void persistField(impact.payload, impact.field.id); else void changeFieldStatus(impact.field); }}>{saving ? 'Saving…' : impact.kind === 'save' ? 'Save changes' : impact.kind === 'archive' ? 'Archive field' : 'Reactivate field'}</Button></div></>}
        </DialogContent>
      </Dialog>
    </div>
  );
}

export function PayrollFields() {
  const { activeCompanyId, activeCompany, loading } = useCompany();
  const [params] = useSearchParams();
  const selected = Number(params.get('field_id'));
  if (loading || !activeCompanyId) return <div role="status" className="p-6 text-sm text-neutral-600">Loading payroll client…</div>;
  return <ClientPayrollFields key={activeCompanyId} companyId={activeCompanyId} companyName={activeCompany?.name || 'this client'} selectedFieldId={Number.isSafeInteger(selected) && selected > 0 ? selected : null} />;
}

export default PayrollFields;
