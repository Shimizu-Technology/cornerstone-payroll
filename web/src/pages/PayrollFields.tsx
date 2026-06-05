import { useEffect, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
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
  { value: '401k_after_tax', label: '401(k) After Tax / Roth', helper: 'Roth or after-tax 401(k) deduction or match.' },
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
  default_amount: 0,
  default_percentage: 0,
  show_in_payroll_grid: true,
  active: true,
  sort_order: 0,
};

export function PayrollFields() {
  const [fields, setFields] = useState<PayrollFieldDefinition[]>([]);
  const [draft, setDraft] = useState<Partial<PayrollFieldDefinition>>(defaultField);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadFields = async () => {
    setLoading(true);
    try {
      const res = await payrollFieldsApi.list();
      setFields(res.payroll_fields);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load payroll fields');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadFields();
  }, []);

  const setKind = (kind: PayrollFieldKind) => {
    setDraft((prev) => ({
      ...prev,
      kind,
      tax_treatment: treatmentOptionsForKind(kind)[0].value,
    }));
  };

  const resetDraft = () => {
    setDraft(defaultField);
    setEditingId(null);
  };

  const saveField = async () => {
    if (!draft.name?.trim()) {
      setError('Name is required');
      return;
    }
    setSaving(true);
    try {
      const payload = {
        ...draft,
        name: draft.name.trim(),
        reporting_group: draft.reporting_group || null,
        default_amount: draft.amount_type === 'fixed' ? Number(draft.default_amount || 0) : null,
        default_percentage: draft.amount_type === 'percentage' ? Number(draft.default_percentage || 0) : null,
      };
      if (editingId) {
        await payrollFieldsApi.update(editingId, payload);
      } else {
        await payrollFieldsApi.create(payload);
      }
      resetDraft();
      await loadFields();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save payroll field');
    } finally {
      setSaving(false);
    }
  };

  const editField = (field: PayrollFieldDefinition) => {
    setEditingId(field.id);
    setDraft(field);
  };

  const archiveField = async (field: PayrollFieldDefinition) => {
    if (!window.confirm(`Archive ${field.name}? Existing payroll history stays unchanged.`)) return;
    try {
      await payrollFieldsApi.archive(field.id);
      if (editingId === field.id) {
        resetDraft();
      }
      await loadFields();
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to archive payroll field');
    }
  };

  return (
    <div>
      <Header
        title="Payroll Fields"
        description="Create reusable client-wide additions, deductions, and employer contributions."
      />

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}

        <Card>
          <CardContent className="space-y-4 py-5">
            <div>
              <h2 className="text-lg font-semibold text-gray-900">{editingId ? 'Edit payroll field' : 'Create payroll field'}</h2>
              <p className="mt-1 text-sm text-gray-500">Define the payroll behavior once, then assign it to employees who need it.</p>
            </div>

            <div className="grid gap-4 lg:grid-cols-4">
              <div className="lg:col-span-2">
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Name</label>
                <Input value={draft.name || ''} onChange={(e) => setDraft((prev) => ({ ...prev, name: e.target.value }))} placeholder="Auto Loan, 401(k), Rent" />
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Type</label>
                <Select value={draft.kind || 'deduction'} onChange={(e) => setKind(e.target.value as PayrollFieldKind)}>
                  {kindOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Tax treatment</label>
                <Select value={draft.tax_treatment || 'post_tax_deduction'} onChange={(e) => setDraft((prev) => ({ ...prev, tax_treatment: e.target.value as PayrollFieldTaxTreatment }))}>
                  {treatmentOptionsForKind(draft.kind || 'deduction').map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Category</label>
                <Select value={draft.category || 'other'} onChange={(e) => setDraft((prev) => ({ ...prev, category: e.target.value as PayrollFieldCategory }))}>
                  {categoryOptions.map((category) => <option key={category} value={category}>{category.replace(/_/g, ' ')}</option>)}
                </Select>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Report group</label>
                <Select value={draft.reporting_group || ''} onChange={(e) => setDraft((prev) => ({ ...prev, reporting_group: e.target.value ? e.target.value as PayrollFieldReportingGroup : null }))}>
                  {reportingGroupOptions.map((option) => <option key={option.value || 'none'} value={option.value}>{option.label}</option>)}
                </Select>
                <p className="mt-1 text-xs text-gray-500">
                  {reportingGroupOptions.find((option) => option.value === (draft.reporting_group || ''))?.helper}
                </p>
              </div>
              <div>
                <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default</label>
                <Select value={draft.amount_type || 'fixed'} onChange={(e) => setDraft((prev) => ({ ...prev, amount_type: e.target.value as PayrollFieldAmountType }))}>
                  {amountTypeOptions.map((type) => <option key={type} value={type}>{type}</option>)}
                </Select>
              </div>
              {draft.amount_type === 'percentage' ? (
                <div>
                  <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default %</label>
                  <Input type="number" step="0.0001" value={draft.default_percentage ?? 0} onChange={(e) => setDraft((prev) => ({ ...prev, default_percentage: Number(e.target.value) }))} />
                </div>
              ) : draft.amount_type === 'fixed' ? (
                <div>
                  <label className="text-xs font-semibold uppercase tracking-wide text-gray-500">Default amount</label>
                  <Input type="number" step="0.01" value={draft.default_amount ?? 0} onChange={(e) => setDraft((prev) => ({ ...prev, default_amount: Number(e.target.value) }))} />
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

            <div className="flex gap-2">
              <Button onClick={saveField} disabled={saving}>{saving ? 'Saving…' : editingId ? 'Save changes' : 'Create field'}</Button>
              {editingId && <Button variant="outline" onClick={resetDraft}>Cancel</Button>}
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
                    <MobileRecordCard key={field.id}>
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-neutral-950">{field.name}</p>
                          <p className="mt-1 text-sm capitalize text-neutral-500">{field.kind.replace(/_/g, ' ')}</p>
                        </div>
                        <span className={field.active ? 'text-sm font-medium text-green-700' : 'text-sm text-neutral-500'}>{field.active ? 'Active' : 'Archived'}</span>
                      </div>
                      <div className="mt-4 grid grid-cols-2 gap-3">
                        <MobileField label="Treatment" value={<span className="capitalize">{field.tax_treatment.replace(/_/g, ' ')}</span>} />
                        <MobileField label="Category" value={<span className="capitalize">{field.category.replace(/_/g, ' ')}</span>} />
                        <MobileField label="Report group" value={field.reporting_group ? reportingGroupOptions.find((option) => option.value === field.reporting_group)?.label || field.reporting_group : 'None'} />
                        <MobileField label="Default" value={field.amount_type === 'percentage' ? `${field.default_percentage || 0}%` : field.amount_type === 'fixed' ? `$${Number(field.default_amount || 0).toFixed(2)}` : 'Manual'} />
                        <MobileField label="Payroll review" value={field.show_in_payroll_grid === false ? 'Hidden' : 'Shown'} />
                      </div>
                      <MobileCardActions>
                        <Button variant="outline" size="sm" onClick={() => editField(field)}>Edit</Button>
                        {field.active && <Button variant="ghost" size="sm" onClick={() => archiveField(field)}>Archive</Button>}
                      </MobileCardActions>
                    </MobileRecordCard>
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
                      <tr key={field.id}>
                        <td className="px-4 py-3 font-medium text-gray-900">{field.name}</td>
                        <td className="px-4 py-3 capitalize">{field.kind.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3 capitalize">{field.tax_treatment.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3 capitalize">{field.category.replace(/_/g, ' ')}</td>
                        <td className="px-4 py-3">{field.reporting_group ? reportingGroupOptions.find((option) => option.value === field.reporting_group)?.label || field.reporting_group : '—'}</td>
                        <td className="px-4 py-3 text-right font-mono">
                          {field.amount_type === 'percentage' ? `${field.default_percentage || 0}%` : field.amount_type === 'fixed' ? `$${Number(field.default_amount || 0).toFixed(2)}` : 'Manual'}
                        </td>
                        <td className="px-4 py-3">{field.active ? 'Active' : 'Archived'}</td>
                        <td className="px-4 py-3 text-right">
                          <Button variant="ghost" size="sm" onClick={() => editField(field)}>Edit</Button>
                          {field.active && <Button variant="ghost" size="sm" onClick={() => archiveField(field)}>Archive</Button>}
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
    </div>
  );
}

export default PayrollFields;
