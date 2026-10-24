import { useState } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import type { TaxConfig } from '@/services/api';

type DraftBracket = { min_income: number; max_income: number | null; rate: number };
export type DraftFiling = { filing_status: string; standard_deduction: number; brackets: DraftBracket[] };

export function TaxWithholdingEditor({ config, saving, onSave, onCancel }: {
  config: TaxConfig; saving: boolean; onSave: (tables: DraftFiling[]) => void; onCancel: () => void;
}) {
  const [tables, setTables] = useState<DraftFiling[]>(() => ['single', 'married', 'head_of_household'].map(status => {
    const current = config.filing_statuses.find(filing => filing.filing_status === status);
    return { filing_status: status, standard_deduction: current?.standard_deduction ?? 0,
      brackets: current?.brackets?.map(({ min_income, max_income, rate }) => ({ min_income, max_income, rate })) ?? [] };
  }));
  const update = (status: string, change: Partial<DraftFiling>) => setTables(current => current.map(filing => filing.filing_status === status ? { ...filing, ...change } : filing));
  const inputClass = 'w-full min-w-24 rounded border border-neutral-300 p-2 text-base sm:text-sm';
  return <div className="space-y-4">
    <p className="text-sm">Enter this year’s annual withholding schedules. Use decimal rates (0.10 = 10%). Leave only the final upper limit empty. Saving keeps the year in draft.</p>
    {tables.map(filing => <fieldset key={filing.filing_status} className="min-w-0 space-y-3 rounded border border-neutral-200 p-3">
      <legend className="px-1 font-medium">{filing.filing_status.replaceAll('_', ' ')}</legend>
      <label className="block text-xs font-medium text-neutral-600">Annual deduction / worksheet adjustment
        <Input aria-label={`${filing.filing_status} annual deduction`} type="number" min="0" step="0.01" value={filing.standard_deduction} className={inputClass}
          onChange={event => update(filing.filing_status, { standard_deduction: Number(event.target.value) })} />
      </label>
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
        <thead><tr><th className="p-1">From ($)</th><th className="p-1">To ($, exclusive)</th><th className="p-1">Rate (decimal)</th><th><span className="sr-only">Actions</span></th></tr></thead>
        <tbody>{filing.brackets.map((bracket, index) => <tr key={index}>
          {(['min_income', 'max_income', 'rate'] as const).map(key => <td className="p-1" key={key}>
            <Input aria-label={`${filing.filing_status} bracket ${index + 1} ${key}`} type="number" min="0" max={key === 'rate' ? '0.999999' : undefined} step="any" value={bracket[key] ?? ''} className={inputClass}
              placeholder={key === 'max_income' ? 'No limit' : undefined}
              onChange={event => update(filing.filing_status, { brackets: filing.brackets.map((row, rowIndex) => rowIndex === index
                ? { ...row, [key]: key === 'max_income' && event.target.value === '' ? null : Number(event.target.value) } : row) })} />
          </td>)}
          <td><Button variant="ghost" size="sm" disabled={saving} aria-label={`Remove ${filing.filing_status} bracket ${index + 1}`} onClick={() => update(filing.filing_status, { brackets: filing.brackets.filter((_, rowIndex) => rowIndex !== index) })}>Remove</Button></td>
        </tr>)}</tbody>
      </table></div>
      <Button variant="outline" size="sm" disabled={saving} onClick={() => update(filing.filing_status, { brackets: [...filing.brackets, { min_income: filing.brackets.at(-1)?.max_income ?? 0, max_income: null, rate: 0 }] })}>Add {filing.filing_status.replaceAll('_', ' ')} bracket</Button>
    </fieldset>)}
    <div className="flex flex-wrap gap-2"><Button disabled={saving} onClick={() => onSave(tables)}>Save draft tables</Button><Button variant="ghost" disabled={saving} onClick={onCancel}>Cancel</Button></div>
  </div>;
}
