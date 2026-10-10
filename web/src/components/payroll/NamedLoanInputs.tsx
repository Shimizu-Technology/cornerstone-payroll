import { NumericInput } from '@/components/ui/numeric-input';
import { formatCurrency } from '@/lib/utils';
import type { NamedLoanOption } from '@/types';

export interface NamedLoanDraft { mode: 'default' | 'override'; amount: number | null }

export function NamedLoanInputs({ options, drafts, includesRecurring, onChange }: {
  options: NamedLoanOption[];
  drafts: Record<string, NamedLoanDraft>;
  includesRecurring: boolean;
  onChange: (loanId: number, draft: NamedLoanDraft) => void;
}) {
  if (!options.length) return null;
  return <fieldset className="min-w-[210px] space-y-3 rounded-xl border border-slate-200 bg-slate-50 p-3">
    <legend className="px-1 text-xs font-semibold text-slate-700">Linked loan repayments</legend>
    <p className="text-xs text-slate-600">These payments credit the saved loan balance after payroll is finalized.</p>
    {options.map(option => {
      const draft = drafts[String(option.loan_id)] || { mode: option.mode, amount: option.requested_amount ?? option.scheduled_amount };
      return <div key={option.loan_id} className="space-y-1">
        <p className="text-sm font-medium text-slate-900">{option.name}</p>
        <p className="text-xs text-slate-600">{option.current_balance == null ? 'Balance not tracked' : `Balance ${formatCurrency(option.current_balance)}`} · Scheduled {formatCurrency(option.scheduled_amount)}</p>
        {!option.eligible && <p role="status" className="text-xs text-amber-800">{option.unavailable_reason || 'This loan is unavailable for this payday.'}</p>}
        <label className="block text-xs font-medium text-slate-700">{option.name} repayment choice
          <select className="mt-1 min-h-11 w-full rounded-lg border border-slate-300 bg-white px-2" value={draft.mode}
            onChange={event => onChange(option.loan_id, { mode: event.target.value as NamedLoanDraft['mode'], amount: option.eligible ? (draft.amount ?? option.scheduled_amount) : 0 })}>
            <option value="default">{!option.eligible ? 'No repayment — loan unavailable' : includesRecurring ? `Scheduled repayment (${formatCurrency(option.scheduled_amount)})` : 'No repayment — recurring setup excluded'}</option>
            <option value="override">{option.eligible ? 'Set repayment for this payroll' : 'Skip repayment for this payroll ($0)'}</option>
          </select>
        </label>
        {draft.mode === 'override' && <label className="block text-xs font-medium text-slate-700">{option.name} repayment amount
          <NumericInput className="mt-1 min-h-11 w-full" value={draft.amount} onValueChange={amount => onChange(option.loan_id, { mode: 'override', amount })} min={0} emptyValue={null} notifyEmptyOnChange fixedDecimalsOnBlur={2} max={option.eligible ? undefined : 0} />
        </label>}
        {!option.eligible && draft.mode === 'override' && Number(draft.amount) > 0 && <p role="alert" className="text-xs text-red-800">This saved repayment is no longer available. Choose no repayment or enter zero, then recalculate.</p>}
        {draft.mode === 'override' && draft.amount === 0 && <p className="text-xs text-slate-600">No repayment from this paycheck. Saved loan setup is unchanged.</p>}
      </div>;
    })}
  </fieldset>;
}
