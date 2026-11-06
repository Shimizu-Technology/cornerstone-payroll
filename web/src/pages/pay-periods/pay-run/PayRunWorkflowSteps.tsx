import type { ReactNode } from 'react';
import { ChevronRight } from 'lucide-react';
import { formatGuamDateTime } from '@/lib/utils';
import type { PayRunSections } from './usePayRunController';
import { payRunSteps } from './payRunWorkflow';
import { PayRunStepAction } from './PayRunProcessingActions';
import { PayRunSourceCheckpoint } from './PayRunSourceCheckpoint';
import { FicaHistoryReviewNotice, PayRunBlockers } from './PayRunBlockers';
import { PayRunFeedback } from './PayRunFeedback';
import { PayRunLoanInputs } from './PayRunLoanInputs';
import { PayRunRoster } from './PayRunRoster';
import { PayRunHoursWorksheet } from './PayRunHoursWorksheet';
import { PayRunSavedRecords } from './PayRunSavedRecords';
import { PayRunEmployeeResults } from './PayRunEmployeeResults';
import { PayRunComparison } from './PayRunComparison';
import { PayRunEmployerTaxes } from './PayRunEmployerTaxes';
import { PayRunEmptyState } from './PayRunEmptyState';
import { PayRunTimecardOcr } from './PayRunTimecardOcr';

function Step({ id, title, number, current, summary, children, savedStatus }: { id: string; title: string; number: number; current: boolean; summary: string; children: ReactNode; savedStatus: string }) {
  return <details key={savedStatus} id={id} tabIndex={-1} open={current} data-current={current || undefined} className={`group scroll-mt-16 rounded-xl border bg-white ${current ? 'border-primary-200' : 'border-neutral-200'}`}>
    <summary className="flex min-h-12 cursor-pointer list-none flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 [&::-webkit-details-marker]:hidden">
      <span className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-neutral-300 text-xs tabular-nums text-neutral-700">{number}</span>
      <h3 className="text-sm font-semibold text-neutral-950">{title}</h3><span className="min-w-0 flex-1 text-xs text-neutral-600">{summary}</span><ChevronRight className="h-4 w-4 shrink-0 text-neutral-600 transition-transform duration-150 ease-out group-open:rotate-90 motion-reduce:transform-none" aria-hidden="true" />
    </summary>
    <div className="space-y-4 border-t border-neutral-200 p-3 sm:p-4">{children}</div>
  </details>;
}

export function PayRunSteps({ sections }: { sections: PayRunSections }) {
  const { payPeriod } = sections.processing;
  const state = payRunSteps(payPeriod);
  const hours = sections.results.payrollItems.reduce((sum, item) => sum + sections.results.payrollItemDisplayedHours(item), 0);
  const held = (payPeriod.time_tracking?.linked_aire_records || []).reduce((sum, record) => sum + (record.payable_line_status?.held.entry_count || 0), 0);
  const committedAt = payPeriod.committed_at || payPeriod.lifecycle?.committed?.timestamp;
  const hasFeedback = Boolean(sections.feedback.error || sections.feedback.calculationNotice || sections.feedback.calendarRefreshError || sections.feedback.worksheetRefreshWarning || sections.feedback.savedImportReloadRequired || sections.feedback.calculationFailures.length);
  const committedSummary = state.committed ? `Committed${committedAt ? ` ${formatGuamDateTime(committedAt)}` : ''}${sections.metadata.processedBy ? ` by ${sections.metadata.processedBy}` : ''}` : state.commitReason || 'Ready to commit the approved payroll';
  return <div className="space-y-3" aria-label="Payroll steps">
    <FicaHistoryReviewNotice note={payPeriod.annual_fica_review_note} />

    <Step id="payroll-hours" title="Hours" number={1} current={state.current === 'hours'} summary={payPeriod.status === 'draft' ? state.hoursReason : `${hours.toFixed(2)} h saved${held ? ` · ${held} held` : ''} · View source and inputs`} savedStatus={`${payPeriod.id}:${payPeriod.status}`}>
      <PayRunStepAction {...sections.processing} step="hours" />
      <div id="payroll-blockers" tabIndex={-1} className="space-y-3"><PayRunBlockers {...sections.blockers} part="hours" /></div>
      <div id="time-tracking-hours"><PayRunSourceCheckpoint {...sections.source} /></div>
      {hasFeedback && state.current === 'hours' && <div id="payroll-feedback" tabIndex={-1}><PayRunFeedback {...sections.feedback} /></div>}
      <div id="payroll-loan-inputs" tabIndex={-1} className="scroll-mt-16 space-y-4"><PayRunLoanInputs {...sections.loans} /><PayRunRoster {...sections.roster} /><PayRunHoursWorksheet {...sections.hours} /></div><PayRunSavedRecords {...sections.results} /><PayRunTimecardOcr {...sections.ocr} /><PayRunEmptyState {...sections.empty} />
    </Step>
    <Step id="payroll-results" title="Results" number={2} current={state.current === 'results'} summary={payPeriod.status === 'draft' ? 'Calculate after hours and pay are added' : `${sections.results.payrollItems.length} employee record${sections.results.payrollItems.length === 1 ? '' : 's'} · Review saved pay`} savedStatus={`${payPeriod.id}:${payPeriod.status}`}>
      {hasFeedback && state.current === 'results' && <div id="payroll-feedback" tabIndex={-1}><PayRunFeedback {...sections.feedback} /></div>}
      {sections.results.payrollItems.length === 0 && <PayRunStepAction {...sections.processing} step="results" />}
      <PayRunEmployeeResults {...sections.results} action={<PayRunStepAction {...sections.processing} step="results" />} />
      {payPeriod.status !== 'draft' && <><details className="rounded-lg border border-neutral-200 p-3"><summary className="cursor-pointer text-sm font-semibold text-neutral-700">Prior-period comparison</summary><div className="pt-3"><PayRunComparison {...sections.comparison} /></div></details>
      <details className="rounded-lg border border-neutral-200 p-3"><summary className="cursor-pointer text-sm font-semibold text-neutral-700">Employer taxes and DRT deposit</summary><div className="pt-3"><PayRunEmployerTaxes {...sections.employerTaxes} /></div></details></>}
    </Step>
    <Step id="payroll-commit" title="Approve & commit" number={3} current={state.current === 'commit'} summary={committedSummary} savedStatus={`${payPeriod.id}:${payPeriod.status}`}>
      {hasFeedback && state.current === 'commit' && <div id="payroll-feedback" tabIndex={-1}><PayRunFeedback {...sections.feedback} /></div>}
      {!state.committed && <PayRunStepAction {...sections.processing} step="commit" />}
      <PayRunBlockers {...sections.blockers} part="approval" />
      {state.committed && <p className="text-sm text-neutral-700">{committedSummary}. Review payments on Checks &amp; payments and the final record on Reports.</p>}
    </Step>
  </div>;
}
