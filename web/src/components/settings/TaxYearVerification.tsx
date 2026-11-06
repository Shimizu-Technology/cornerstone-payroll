import { useState } from 'react';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';
import { TaxWithholdingEditor } from './TaxWithholdingEditor';
import { taxConfigsApi, type TaxConfig, type TaxConfigBracket } from '@/services/api';

const fields = [
  ['ss_wage_base', 'Social Security wage base', 'money'],
  ['ss_rate', 'Social Security rate', 'percent'],
  ['medicare_rate', 'Medicare rate', 'percent'],
  ['additional_medicare_rate', 'Additional Medicare rate', 'percent'],
  ['additional_medicare_threshold', 'Additional Medicare threshold', 'money'],
] as const;

export function TaxYearVerification({ config, previous, onSaved, onReload }: {
  config: TaxConfig; previous: TaxConfig | null; onSaved: () => Promise<void>; onReload?: () => Promise<void>;
}) {
  const [sourceNote, setSourceNote] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [editingTables, setEditingTables] = useState(false);
  const [needsReviewRefresh, setNeedsReviewRefresh] = useState(false);
  const format = (value: number, kind: string) => kind === 'percent'
    ? `${(value * 100).toFixed(2)}%` : value.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
  const act = async (action: () => Promise<unknown>) => {
    setSaving(true); setError('');
    try { await action(); setSourceNote(''); setEditingTables(false); await onSaved(); }
    catch (cause) {
      const message = cause instanceof Error ? cause.message : 'Could not save. Try again.';
      setError(message);
      if (message.includes('changed after')) setNeedsReviewRefresh(true);
    }
    finally { setSaving(false); }
  };
  const reloadReview = async () => {
    setSaving(true);
    try { await (onReload ?? onSaved)(); setNeedsReviewRefresh(false); setError(''); setEditingTables(false); }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not reload. Try again.'); }
    finally { setSaving(false); }
  };
  return <section aria-label="Tax year verification" className="mb-6 space-y-4 rounded-lg border border-neutral-200 p-4">
    <h3 className="text-lg font-semibold">{config.tax_year} · {config.verification_status === 'verified' ? 'Verified' : 'Draft — payroll blocked'}</h3>
    {config.verification_status !== 'verified' && <p role="status" className="text-warning-800">
      {config.tax_year} tax tables have not been verified. An administrator must verify them before {config.tax_year} payroll can be calculated.
      {' '}Copied values and the active/default flag do not establish verification. Review against sources for this year.
    </p>}
    <p className="break-words text-sm text-neutral-700">{config.source_references || 'No source references recorded.'}</p>
    {config.verified_at && <p className="text-sm">Verified by {config.verified_by} on {new Date(config.verified_at).toLocaleString()}. Editing values requires verification again.</p>}
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <caption className="mb-2 text-left font-medium">Compare with the prior year</caption>
        <thead><tr><th className="p-2">Value</th><th className="p-2">{previous?.tax_year ?? 'Prior year'}</th><th className="p-2">{config.tax_year}</th></tr></thead>
        <tbody>{fields.map(([key, label, kind]) => <tr key={key} className="border-t border-neutral-200">
          <th className="p-2 font-normal">{label}</th><td className="p-2 tabular-nums">{previous ? format(previous[key], kind) : 'Absent'}</td><td className="p-2 tabular-nums">{format(config[key], kind)}</td>
        </tr>)}</tbody>
      </table>
    </div>
    {['single', 'married', 'head_of_household'].map(status => {
      const oldFiling = previous?.filing_statuses.find(filing => filing.filing_status === status);
      const filing = config.filing_statuses.find(filing => filing.filing_status === status);
      const count = Math.max(oldFiling?.brackets?.length ?? 0, filing?.brackets?.length ?? 0);
      const bracketText = (bracket: TaxConfigBracket | undefined) => bracket
        ? `${format(bracket.min_income, 'money')}–${bracket.max_income === null ? 'No limit' : format(bracket.max_income, 'money')} at ${format(bracket.rate, 'percent')}` : 'Absent / held';
      return <details key={status} className="rounded border border-neutral-200 p-3">
        <summary className="cursor-pointer font-medium">{status.replaceAll('_', ' ')} withholding comparison{!filing && ' — absent / held'}</summary>
        <div className="mt-3 overflow-x-auto"><table className="w-full text-left text-sm">
          <thead><tr><th className="p-2">Value</th><th className="p-2">{previous?.tax_year ?? 'Prior year'}</th><th className="p-2">{config.tax_year}</th></tr></thead>
          <tbody><tr><th className="p-2 font-normal">Deduction / adjustment</th><td className="p-2">{oldFiling ? format(oldFiling.standard_deduction, 'money') : 'Absent'}</td><td className="p-2">{filing ? format(filing.standard_deduction, 'money') : 'Absent / held'}</td></tr>
            {Array.from({ length: count }, (_, index) => <tr key={index}><th className="p-2 font-normal">Bracket {index + 1}</th><td className="p-2">{bracketText(oldFiling?.brackets?.[index])}</td><td className="p-2">{bracketText(filing?.brackets?.[index])}</td></tr>)}
          </tbody>
        </table></div>
      </details>;
    })}
    <p className="text-sm text-neutral-700">Retirement limits are configured separately. Missing 2027 limits must remain held until IRS publication.</p>
    <Button variant="outline" disabled={saving} onClick={() => setEditingTables(true)}>Enter withholding tables</Button>
    {editingTables && <TaxWithholdingEditor config={config} saving={saving}
      onSave={tables => void act(() => taxConfigsApi.replaceWithholding(config.id, tables))}
      onCancel={() => setEditingTables(false)} />}
    {config.verification_status !== 'verified' && <form className="space-y-2" onSubmit={event => { event.preventDefault(); void act(() => taxConfigsApi.verify(config.id, sourceNote, config.review_digest ?? '')); }}>
      <label htmlFor="tax-source-note" className="block text-xs font-medium text-neutral-600">Verification source note (required)</label>
      <p className="text-sm">Record the year, publication URLs and what you checked, including all withholding schedules. Verification authorizes live payroll for this year. Recalculate existing drafts after verification, before approval.</p>
      <Textarea id="tax-source-note" required value={sourceNote} onChange={event => setSourceNote(event.target.value)} className="w-full rounded border border-neutral-300 p-2 text-base sm:text-sm" rows={3} />
      <Button type="submit" disabled={saving || needsReviewRefresh || !config.review_digest || !sourceNote.trim()}>{saving ? 'Saving…' : `Verify ${config.tax_year} tax tables`}</Button>
    </form>}
    {error && <p role="alert" className="text-danger-700">{error}</p>}
    {needsReviewRefresh && <Button variant="outline" disabled={saving} onClick={() => void reloadReview()}>Reload values for review</Button>}
  </section>;
}
