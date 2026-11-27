import type { ReactNode } from 'react';
import { ChevronRight } from 'lucide-react';
import { formatGuamDateTime } from '@/lib/utils';
import type { PayRunSections } from './usePayRunController';
import { payRunSteps } from './payRunWorkflow';
import { PayRunStepAction } from './PayRunProcessingActions';
import { PayRunSourceCheckpoint } from './PayRunSourceCheckpoint';
import { FicaHistoryReviewNotice } from '@/components/payroll/FicaHistoryReviewNotice';
import { PayRunBlockers, PayRunClientFiles } from './PayRunBlockers';
import { PayRunFeedback } from './PayRunFeedback';
import { PayRunLoanInputs } from './PayRunLoanInputs';
import { ExpectedEntriesPanel } from './ExpectedEntriesPanel';
import { PayRunRoster } from './PayRunRoster';
import { PayRunHoursWorksheet } from './PayRunHoursWorksheet';
import { PayRunSavedRecords } from './PayRunSavedRecords';
import { PayRunEmployeeResults } from './PayRunEmployeeResults';
import { PayRunComparison } from './PayRunComparison';
import { PayRunEmployerTaxes } from './PayRunEmployerTaxes';
import { PayRunEmptyState } from './PayRunEmptyState';
import { PayRunTimecardOcr } from './PayRunTimecardOcr';
import { NewHireDocumentsNotice } from './NewHireDocumentsNotice';

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
  const committedAt = payPeriod.committed_at || payPeriod.lifecycle?.committed?.timestamp;
  const hasFeedback = Boolean(sections.feedback.error || sections.feedback.calculationNotice || sections.feedback.calendarRefreshError || sections.feedback.worksheetRefreshWarning || sections.feedback.savedImportReloadRequired || sections.feedback.calculationFailures.length);
  const committedSummary = state.committed ? `Committed${committedAt ? ` ${formatGuamDateTime(committedAt)}` : ''}${sections.metadata.processedBy ? ` by ${sections.metadata.processedBy}` : ''}` : state.commitReason || 'Ready to commit the approved payroll';
  return <div className="space-y-3" aria-label="Payroll steps">
    {!!payPeriod.ineligible_workers?.length && <div id="payroll-ineligible-workers" tabIndex={-1} role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-900">
      <h2 className="font-semibold">Ineligible on this run</h2>
      <ul>{payPeriod.ineligible_workers.map(worker => <li key={worker.employee_id}>{worker.reason}{worker.resolution && <p>{worker.resolution}</p>}</li>)}</ul>
      <p>For workers without AIRE time or tax evidence, use Edit payroll → Remove from Payroll, or reactivate them, before approving or committing. No paychecks are removed automatically.</p>
    </div>}
    <NewHireDocumentsNotice gaps={payPeriod.new_hire_document_gaps} companyId={sections.feedback.companyId} returnTo={sections.feedback.currentPath} status={payPeriod.status} />
    <PayRunBlockers {...sections.blockers} part="lifecycle" />
    <ExpectedEntriesPanel key={payPeriod.id} onUnapprove={sections.processing.handleUnapprove} payPeriod={payPeriod} disabled={sections.roster.processing || sections.roster.financialActionsHeld || !sections.roster.canEditPayPeriod || (payPeriod.status !== 'approved' && sections.roster.hasStagedWorksheetChanges)}
      onRestore={employeeId => sections.roster.handleRestoreEmployee(employeeId)} addBackNotice={sections.roster.addBackNotice} onCalculate={sections.roster.onCalculateExpectedEntry} onSaved={() => sections.roster.loadPayPeriod(payPeriod.id, true, true)} onEnterPay={id => {
        sections.roster.setAdditionalEmployeeIds(prev => new Set([...prev, id]));
        sections.roster.setHoursMap(prev => ({ ...prev, [id]: prev[id] || { regular: 0, overtime: 0 } }));
        const step = document.getElementById('payroll-hours') as HTMLDetailsElement | null;
        if (step) step.open = true;
        document.getElementById('payroll-loan-inputs')?.scrollIntoView({ block: 'start' });
      }} />
    <PayRunClientFiles payPeriod={payPeriod} />
    <FicaHistoryReviewNotice key={`fica-review-${payPeriod.id}`} payPeriod={payPeriod} showDisclosure />

    <Step id="payroll-hours" title="Hours" number={1} current={state.current === 'hours'} summary={payPeriod.status === 'draft' ? state.hoursReason : `${hours.toFixed(2)} h saved · View source and inputs`} savedStatus={`${payPeriod.id}:${payPeriod.status}`}>
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
