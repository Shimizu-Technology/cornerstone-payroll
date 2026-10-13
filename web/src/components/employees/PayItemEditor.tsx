import { X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { newPayItemDraft, payItemGroups, payItemTreatments, type PayItemDraft } from '@/lib/pay-items';
import { formatCurrency } from '@/lib/utils';
import type { PayrollFieldAmountType, PayrollFieldCategory, PayrollFieldDefinition, PayrollFieldReportingGroup, PayrollFieldTaxTreatment } from '@/types';

const categories: PayrollFieldCategory[] = ['other', 'loan', 'retirement', 'insurance', 'rent', 'allotment', 'reimbursement', 'garnishment', 'child_support', 'phone', 'benefit'];
const reportGroups: Array<{ value: PayrollFieldReportingGroup | ''; label: string }> = [
  { value: '', label: 'No special report group' },
  { value: '401k_pre_tax', label: '401(k) Pre-Tax' },
  { value: '401k_after_tax', label: 'Roth 401(k)' },
  { value: '401k_non_roth_after_tax', label: '401(k) non-Roth after-tax' },
  { value: 'retirement_other', label: 'Other Retirement' },
];

interface Props {
  draft: PayItemDraft;
  employeeName: string;
  companyName: string;
  availableFields: PayrollFieldDefinition[];
  selectedField?: PayrollFieldDefinition;
  linkedLoan: boolean;
  duplicateName: boolean;
  saving: boolean;
  error: string | null;
  onChange: (patch: Partial<PayItemDraft>) => void;
  onSelectField: (id: number) => void;
  onSave: () => void;
  onClose: () => void;
}

export function PayItemEditor({ draft, employeeName, companyName, availableFields, selectedField, linkedLoan, duplicateName, saving, error, onChange, onSelectField, onSave, onClose }: Props) {
  const editing = Boolean(draft.assignmentId);
  const group = payItemGroups.find((item) => item.kind === draft.kind)!;
  const sharedEdit = editing && draft.scope === 'client_wide';
  const metadataEditable = !linkedLoan && !sharedEdit && draft.source === 'new';
  const valueEditable = !linkedLoan && draft.amountType !== 'manual';
  const defaultValue = draft.amountType === 'percentage' ? selectedField?.default_percentage : selectedField?.default_amount;
  const defaultDescription = draft.amountType === 'percentage' ? `${defaultValue ?? 0}%` : formatCurrency(defaultValue ?? 0);
  const canUseDefault = draft.source === 'existing' || editing;
  const title = `${editing ? 'Edit' : 'Add'} ${group.singular === 'contribution' ? 'employer contribution' : group.singular}`;

  return <Dialog open onOpenChange={(open) => { if (!open) onClose(); }} dismissOnEscape={!saving}>
    <DialogContent className="dialog-center-mobile !max-h-[92dvh] !p-0 sm:!mx-4" aria-describedby="pay-item-description">
      <form onSubmit={(event) => { event.preventDefault(); event.stopPropagation(); onSave(); }}>
        <div className="border-b border-neutral-200 px-5 pb-4 pt-5 sm:px-6">
          <div className="flex items-start justify-between gap-3">
            <div><DialogTitle>{title}</DialogTitle><p id="pay-item-description" className="mt-1 text-sm text-neutral-600">{employeeName} · {companyName}</p></div>
            <Button type="button" variant="ghost" size="sm" aria-label="Close pay item" onClick={onClose} disabled={saving}><X className="h-4 w-4" /></Button>
          </div>
        </div>
        <fieldset disabled={saving} className="space-y-5 px-5 py-5 sm:px-6">
          {!editing && <fieldset className="space-y-2"><legend className="mb-2 text-sm font-semibold text-neutral-900">Choose an item</legend>
            <label className="flex gap-2 text-sm"><input type="radio" name="pay-item-source" checked={draft.source === 'new'} onChange={() => onChange({ ...newPayItemDraft(draft.kind), dirty: true })} />Create new item</label>
            <label className="flex gap-2 text-sm"><input type="radio" name="pay-item-source" checked={draft.source === 'existing'} disabled={availableFields.length === 0} onChange={() => onChange({ source: 'existing', scope: 'client_wide', fieldId: undefined, name: '', useDefault: true, amount: '' })} />Use existing client field</label>
            {availableFields.length === 0 && <p className="text-xs text-neutral-500">No unassigned reusable {group.singular}s are available yet.</p>}
          </fieldset>}
          {draft.source === 'existing' && !editing && <label className="block text-sm font-medium">Client field
            <Select aria-label="Client field" className="mt-1" value={draft.fieldId || ''} onChange={(event) => onSelectField(Number(event.target.value))}><option value="">Choose a field</option>{availableFields.map((field) => <option key={field.id} value={field.id}>{field.name}</option>)}</Select>
          </label>}
          {draft.source === 'new' && !editing && <fieldset className="rounded-xl border border-primary-100 bg-primary-50/60 p-3"><legend className="px-1 text-sm font-semibold">Applies to</legend>
            <label className="flex items-start gap-2 text-sm"><input className="mt-1" type="radio" name="pay-item-scope" aria-label={`Only ${employeeName}`} checked={draft.scope === 'employee_only'} onChange={() => onChange({ scope: 'employee_only' })} /><span>Only {employeeName}<span className="mt-0.5 block text-xs text-neutral-600">This item belongs to this person.</span></span></label>
            <label className="mt-3 flex items-start gap-2 text-sm"><input className="mt-1" type="radio" name="pay-item-scope" aria-label={`Reusable for ${companyName}`} checked={draft.scope === 'client_wide'} onChange={() => onChange({ scope: 'client_wide' })} /><span>Reusable for {companyName}<span className="mt-0.5 block text-xs text-neutral-600">Save here to assign it to {employeeName}. Other people receive it only when assigned.</span></span></label>
          </fieldset>}
          {editing && <p className="rounded-xl bg-neutral-50 p-3 text-sm">{sharedEdit ? `Client-wide field · editing only ${employeeName}’s amount and payday dates.` : `Employee-specific · only ${employeeName}.`}</p>}
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="block text-sm font-medium sm:col-span-2">Name<Input className="mt-1" value={draft.name} onChange={(event) => onChange({ name: event.target.value })} disabled={!metadataEditable} maxLength={255} placeholder="e.g. Assistant Chief Pilot" autoFocus={metadataEditable} /></label>
            <label className="block text-sm font-medium">Tax treatment<Select aria-label="Tax treatment" className="mt-1" value={draft.treatment} disabled={!metadataEditable} onChange={(event) => onChange({ treatment: event.target.value as PayrollFieldTaxTreatment })}>{payItemTreatments(draft.kind).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</Select></label>
            <label className="block text-sm font-medium">Amount type<Select aria-label="Amount type" className="mt-1" value={draft.amountType} disabled={!metadataEditable} onChange={(event) => onChange({ amountType: event.target.value as PayrollFieldAmountType, useDefault: false })}><option value="fixed">Fixed amount</option><option value="percentage">Percentage</option><option value="manual">Enter each payroll</option></Select></label>
          </div>
          {canUseDefault && valueEditable && <fieldset className="space-y-2"><legend className="mb-2 text-sm font-semibold">Amount for {employeeName}</legend>
            <label className="flex gap-2 text-sm"><input type="radio" name="pay-item-default" checked={draft.useDefault} onChange={() => onChange({ useDefault: true })} />{draft.scope === 'client_wide' ? 'Use client default' : 'Use item default'} ({defaultDescription})</label>
            <label className="flex gap-2 text-sm"><input type="radio" name="pay-item-default" checked={!draft.useDefault} onChange={() => onChange({ useDefault: false })} />Set employee amount</label>
            <p className="text-xs text-neutral-600">An employee amount stays separate from the client default. Zero explicitly applies no amount.</p>
          </fieldset>}
          {draft.amountType === 'manual' ? <p className="rounded-xl bg-neutral-50 p-3 text-sm text-neutral-700">Review this item’s amount on each payroll. Existing saved amounts are kept when you edit dates or notes. Payday dates below control when it is available.</p>
            : !linkedLoan && <label className="block text-sm font-medium">{draft.amountType === 'percentage' ? 'Percentage' : 'Amount'}<Input aria-label={draft.amountType === 'percentage' ? 'Percentage' : 'Amount'} aria-describedby="pay-item-amount-help" className="mt-1" type="number" min="0" step={draft.amountType === 'percentage' ? '0.0001' : '0.01'} value={draft.useDefault ? defaultValue ?? 0 : draft.amount} disabled={draft.useDefault} onChange={(event) => onChange({ amount: event.target.value })} placeholder="0.00" /><span id="pay-item-amount-help" className="mt-1 block text-xs font-normal text-neutral-600">{draft.amountType === 'percentage' ? 'Percentage of eligible gross pay.' : 'Amount on each eligible regular paycheck.'}</span></label>}
          {linkedLoan && <p className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm">This item repays a tracked loan. Change its amount and balance in Loans; payday dates and notes can be edited here.</p>}
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="block text-sm font-medium">First payday<Input aria-label="First payday" aria-describedby="pay-item-start-help" className="mt-1" type="date" value={draft.startDate} onChange={(event) => onChange({ startDate: event.target.value })} /><span id="pay-item-start-help" className="mt-1 block text-xs font-normal text-neutral-600">Blank means no start-date restriction.</span></label>
            <label className="block text-sm font-medium">Last payday<Input aria-label="Last payday" aria-describedby="pay-item-end-help" className="mt-1" type="date" min={draft.startDate || undefined} value={draft.endDate} onChange={(event) => onChange({ endDate: event.target.value })} /><span id="pay-item-end-help" className="mt-1 block text-xs font-normal text-neutral-600">Blank continues until stopped.</span></label>
          </div>
          <details className="rounded-xl border border-neutral-200 p-3"><summary className="cursor-pointer text-sm font-semibold">More options</summary><div className="mt-4 grid gap-4 sm:grid-cols-2">
            <label className="block text-sm font-medium">Category<Select aria-label="Category" className="mt-1" value={draft.category} disabled={!metadataEditable} onChange={(event) => onChange({ category: event.target.value as PayrollFieldCategory, reportingGroup: event.target.value === 'retirement' ? draft.reportingGroup : '' })}>{categories.map((category) => <option key={category} value={category}>{category.replace(/_/g, ' ')}</option>)}</Select></label>
            {draft.category === 'retirement' && <label className="block text-sm font-medium">Report group<Select aria-label="Report group" className="mt-1" value={draft.reportingGroup} disabled={!metadataEditable} onChange={(event) => onChange({ reportingGroup: event.target.value as PayrollFieldReportingGroup | '' })}>{reportGroups.map((group) => <option key={group.value} value={group.value}>{group.label}</option>)}</Select></label>}
            {draft.kind !== 'addition' && <><label className="block text-sm font-medium">Payee<Input className="mt-1" value={draft.payee} disabled={!metadataEditable} onChange={(event) => onChange({ payee: event.target.value })} /></label><label className="block text-sm font-medium">Reference number<Input className="mt-1" value={draft.reference} disabled={!metadataEditable} onChange={(event) => onChange({ reference: event.target.value })} /></label></>}
            <label className="block text-sm font-medium sm:col-span-2">Notes<Input aria-label="Notes" aria-describedby="pay-item-notes-help" className="mt-1" value={draft.notes} onChange={(event) => onChange({ notes: event.target.value })} /><span id="pay-item-notes-help" className="mt-1 block text-xs font-normal text-neutral-600">Reference only. Use the payday fields to control dates.</span></label>
          </div></details>
          {draft.category === 'loan' && !linkedLoan && <p className="text-sm text-amber-900">A deduction named “loan” does not track a balance or stop at payoff. Use Loans for a tracked repayment.</p>}
          {draft.category === 'retirement' && <p className="text-sm text-amber-900">Use the person’s retirement plan to change an election or catch-up limit. A separate item adds another contribution.</p>}
          {duplicateName && <div className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>This person already has an item with this name. Edit that item to change it. Saving another item can apply both amounts.</p><label className="mt-3 flex items-start gap-2"><input className="mt-1" type="checkbox" checked={draft.duplicateAcknowledged === true} onChange={(event) => onChange({ duplicateAcknowledged: event.target.checked })} />I intend to add a separate item</label></div>}
          {error && <ActionFeedback tone="error" message={error} />}
        </fieldset>
        <div className="sticky bottom-0 flex flex-col-reverse gap-2 border-t border-neutral-200 bg-white px-5 py-4 sm:flex-row sm:justify-end sm:px-6">
          <Button type="button" variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button type="submit" disabled={saving}>{saving ? 'Saving…' : `Save ${group.singular}`}</Button>
        </div>
      </form>
    </DialogContent>
  </Dialog>;
}
