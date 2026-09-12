import type { ReactElement } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '../ui/card';
import { formatCurrency, formatDate } from '../../lib/utils';
import { payrollComponentSource, type PayrollComponentDisclosure, type PayrollComponentLine } from '../../lib/payroll-tax-summary';
import type { PayrollItem } from '../../types';

export function PayrollResultBreakdown({ disclosure }: { disclosure: PayrollComponentDisclosure }): ReactElement {
  const totals = disclosure.reconciliation;
  const difference = Math.round((totals.gross_pay + totals.other_pay - totals.employee_taxes - totals.other_deductions - totals.net_pay) * 100);
  return <Card>
    <CardHeader><CardTitle>Saved paycheck breakdown</CardTitle><p className="mt-2 text-sm text-neutral-500">The same saved components used in payroll reports. Employer contributions do not reduce take-home pay.</p></CardHeader>
    <CardContent className="space-y-6">
      <div className="grid gap-6 lg:grid-cols-2">
        <ComponentList title="Taxable earnings" entries={disclosure.earnings} />
        <ComponentList title="Non-taxable additions" entries={disclosure.other_pay} />
        <ComponentList title="Employee taxes" entries={disclosure.taxes} />
        <ComponentList title="Employee deductions" entries={disclosure.deductions} />
        <ComponentList title="Employer contributions" entries={disclosure.employer_contributions} />
      </div>
      <p className="border-t border-neutral-200 pt-4 text-sm leading-6 text-neutral-700">
        Gross {formatCurrency(totals.gross_pay)} + non-taxable additions {formatCurrency(totals.other_pay)} − employee taxes {formatCurrency(totals.employee_taxes)} − other deductions {formatCurrency(totals.other_deductions)}{difference === 0 ? " = " : "; saved "}net pay {formatCurrency(totals.net_pay)}.
      </p>
      {difference !== 0 && <p className="text-sm text-warning-800">The retained components differ from saved net pay by {formatCurrency(difference / 100)}. Review the original payroll records before relying on this breakdown.</p>}
    </CardContent>
  </Card>;
}

function ComponentList({ title, entries }: { title: string; entries: PayrollComponentLine[] }): ReactElement {
  return <section><h2 className="text-sm font-bold text-neutral-950">{title}</h2>{entries.length ? <dl className="mt-4 space-y-2">{entries.map((entry, index) => {
    const source = payrollComponentSource(entry.source);
    return <div key={`${entry.label}-${index}`} className="flex items-center justify-between gap-4 rounded-xl bg-neutral-50 px-4 py-2 text-sm"><dt className="font-medium text-neutral-700">{entry.label}{source && <span className="block text-xs font-normal text-neutral-500">{source}</span>}{entry.treatment && <span className="block text-xs font-normal text-neutral-500">{entry.treatment === 'pre_tax' ? 'Pre-tax deduction' : 'After-tax deduction'}</span>}</dt><dd className="font-semibold tabular-nums text-neutral-950">{formatCurrency(Number(entry.amount || 0))}</dd></div>;
  })}</dl> : <p className="mt-4 text-sm text-neutral-500">None applied.</p>}</section>;
}

export function PaycheckWithholdingContext({ item }: { item: PayrollItem }): ReactElement {
  const value = item.tax_rule_snapshot?.w4;
  const w4 = value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
  const text = (key: string): string => String(w4?.[key] ?? 'Not recorded');
  const amount = (key: string): string => w4?.[key] == null ? 'Not recorded' : formatCurrency(Number(w4[key]));
  return <Card>
    <CardHeader><CardTitle>W-4 used for this paycheck</CardTitle></CardHeader>
    <CardContent className="space-y-3 text-sm leading-6 text-neutral-700">
      {w4 ? <>
        <p>Filing status: <strong>{text('filing_status_entered').replaceAll('_', ' ')}</strong>. Form revision: {text('form_version')}. Applied from {w4.effective_on ? formatDate(String(w4.effective_on)) : 'an unrecorded effective date'}.</p>
        <p>Step 3 annual credit: <strong>{amount('step3_dependent_credit')}</strong>. This annual credit reduces calculated withholding across the year's pay periods; it is not extra pay. It can reduce federal income tax to zero even when the filing status is Single.</p>
        <p>Step 2 multiple jobs: {w4.step2_multiple_jobs === true ? 'Checked' : w4.step2_multiple_jobs === false ? 'Unchecked' : 'Not recorded'}. Step 4(a) annual other income: {amount('step4a_other_income')}. Step 4(b) annual deductions: {amount('step4b_deductions')}. Additional withholding applied to this paycheck: <strong>{formatCurrency(Number(item.additional_withholding || 0))}</strong>.</p>
        <p className="text-neutral-500">Election #{text('election_id')} · Source: {text('election_source').replaceAll('_', ' ')}. The application effective date is separate from the form's signing date.</p>
        {(w4.signed_on || w4.source_reference) ? <p className="text-neutral-500">{w4.signed_on ? `Signed ${formatDate(String(w4.signed_on))}. ` : ''}{w4.source_reference ? `Document reference: ${String(w4.source_reference)}` : ''}</p> : null}
      </> : <p>No W-4 snapshot was retained for this paycheck. Review its source records; today's employee settings may differ from those used for this result.</p>}
      {(item.withholding_tax_override != null || Number(item.withholding_tax_adjustment || 0) !== 0) && <p className="font-medium text-warning-800">This paycheck includes a manual federal withholding {item.withholding_tax_override != null ? `override of ${formatCurrency(Number(item.withholding_tax_override))}` : `adjustment of ${formatCurrency(Number(item.withholding_tax_adjustment))}`}.</p>}
    </CardContent>
  </Card>;
}

export function PaycheckRetirementContext({ item }: { item: PayrollItem }): ReactElement {
  const value = item.retirement_rule_snapshot;
  const snapshot = value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
  const election = snapshot?.election && typeof snapshot.election === 'object' && !Array.isArray(snapshot.election) ? snapshot.election as Record<string, unknown> : null;
  const annualLimit = snapshot?.annual_limit && typeof snapshot.annual_limit === 'object' && !Array.isArray(snapshot.annual_limit) ? snapshot.annual_limit as Record<string, unknown> : null;
  const requested = snapshot?.requested && typeof snapshot.requested === 'object' && !Array.isArray(snapshot.requested) ? snapshot.requested as Record<string, unknown> : {};
  const applied = snapshot?.applied && typeof snapshot.applied === 'object' && !Array.isArray(snapshot.applied) ? snapshot.applied as Record<string, unknown> : {};
  const employerMatch = snapshot?.employer_match && typeof snapshot.employer_match === 'object' && !Array.isArray(snapshot.employer_match) ? snapshot.employer_match as Record<string, unknown> : {};
  const explanations = Array.isArray(snapshot?.explanations) ? snapshot.explanations.map(String) : [];
  if (!snapshot || !election) return <Card><CardHeader><CardTitle>Retirement rules used</CardTitle></CardHeader><CardContent><p className="text-sm leading-6 text-neutral-600">No retirement-rule snapshot was retained for this paycheck. The saved deduction amounts remain authoritative, but today’s plan settings may differ.</p></CardContent></Card>;

  const requestedTotal = Number(requested.traditional || 0) + Number(requested.roth || 0);
  const appliedTotal = Number(applied.traditional || 0) + Number(applied.roth || 0);
  const employerMatchTotal = Number(employerMatch.traditional || 0) + Number(employerMatch.roth || 0);
  const sourceUrl = typeof annualLimit?.source_url === 'string' ? annualLimit.source_url : null;
  return <Card>
    <CardHeader><CardTitle>Retirement rules used</CardTitle><p className="mt-2 text-sm text-neutral-500">The exact election, YTD baseline, and annual limit retained with this paycheck.</p></CardHeader>
    <CardContent className="space-y-4 text-sm leading-6 text-neutral-700">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <RuleValue label="Plan" value={String(election.plan_name || 'Not recorded')} />
        <RuleValue label="Eligible pay" value={formatCurrency(Number(snapshot.eligible_compensation || 0))} />
        <RuleValue label="Employee YTD before" value={formatCurrency(Number(snapshot.ytd_employee_deferral_before || 0))} />
        <RuleValue label="Employee applied" value={formatCurrency(appliedTotal)} />
        <RuleValue label="Employer match this check" value={formatCurrency(employerMatchTotal)} />
        <RuleValue label="Employer match YTD before" value={formatCurrency(Number(employerMatch.prior_ytd || 0))} />
      </div>
      <p>Requested {formatCurrency(requestedTotal)}: {formatCurrency(Number(requested.traditional || 0))} Traditional and {formatCurrency(Number(requested.roth || 0))} Roth. Applied {formatCurrency(Number(applied.traditional || 0))} Traditional and {formatCurrency(Number(applied.roth || 0))} Roth.</p>
      <p>Employer match applied: {formatCurrency(Number(employerMatch.traditional || 0))} Traditional and {formatCurrency(Number(employerMatch.roth || 0))} Roth.</p>
      {annualLimit ? <p>For pay date year {String(annualLimit.tax_year)}, the saved employee elective-deferral limit was <strong>{formatCurrency(Number(annualLimit.elective_deferral_limit || 0))}</strong>{snapshot.employee_age_at_year_end ? `; age at year end was ${String(snapshot.employee_age_at_year_end)}` : ''}. {snapshot.roth_catch_up_required === true ? 'Roth-only catch-up treatment applied.' : ''} {sourceUrl && <a className="font-semibold text-primary-700 underline decoration-primary-200 underline-offset-2 hover:text-primary-900" href={sourceUrl} target="_blank" rel="noreferrer">View the saved IRS source</a>}</p> : <p className="text-warning-800">No annual limit record was available for this historical paycheck.</p>}
      {explanations.length > 0 && <ul className="space-y-2 rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-warning-900">{explanations.map((explanation) => <li key={explanation}>• {explanation}</li>)}</ul>}
    </CardContent>
  </Card>;
}

function RuleValue({ label, value }: { label: string; value: string }): ReactElement {
  return <div className="rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3"><p className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-1 font-semibold text-neutral-900">{value}</p></div>;
}
