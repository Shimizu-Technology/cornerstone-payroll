import { Link, useLocation } from 'react-router';
import { useEffect } from 'react';
import { useCompany } from '@/contexts/CompanyContext';
import { payRunPath } from '@/lib/routes';
import { needsSourceCoverageAcknowledgement } from '@/lib/payroll-source-coverage';
import { PayRunRecordHeader } from './pay-periods/pay-run/PayRunRecordHeader';
import { usePayRunController } from './pay-periods/pay-run/usePayRunController';
import type { PayPeriodDetailProps } from './pay-periods/pay-run/payRunSupport';
import { PayRunSteps } from './pay-periods/pay-run/PayRunWorkflowSteps';
import { SourceCoverageDialog } from './pay-periods/pay-run/SourceCoverageDialog';
import { PayRunReviewDialogs } from './pay-periods/pay-run/PayRunReviewDialogs';
import { PayRunSummary } from './pay-periods/pay-run/PayRunSummary';
import { PayRunProcessingActions } from './pay-periods/pay-run/PayRunProcessingActions';
import { PayRunMetadata } from './pay-periods/pay-run/PayRunMetadata';
import { RefreshSetupDialog } from './pay-periods/pay-run/RefreshSetupDialog';
import { PayRunLiabilities } from './pay-periods/pay-run/PayRunLiabilities';
import { PayRunLinkedCorrections } from './pay-periods/pay-run/PayRunLinkedCorrections';
import { PayRunChecks } from './pay-periods/pay-run/PayRunChecks';
import { PayRunSupportingDetails } from './pay-periods/pay-run/PayRunSupportingDetails';
import { PayRunNonEmployeeChecks } from './pay-periods/pay-run/PayRunNonEmployeeChecks';
import { PayRunCheckPrintDialog } from './pay-periods/pay-run/PayRunCheckPrintDialog';
import { PayRunReports } from './pay-periods/pay-run/PayRunReports';
import { PayRunTimecardHistory } from './pay-periods/pay-run/PayRunTimecardHistory';
import { PayRunCorrections } from './pay-periods/pay-run/PayRunCorrections';
import { PayRunDialogs } from './pay-periods/pay-run/PayRunDialogs';

export function PayPeriodDetail(props: PayPeriodDetailProps) {
  const state = usePayRunController(props);
  const { activeCompany } = useCompany();
  const location = useLocation();
  const activeTab = props.activeTab ?? 'work';
  useEffect(() => {
    if (!location.hash || state.status !== 'ready') return;
    let fragment: string;
    try { fragment = decodeURIComponent(location.hash.slice(1)); } catch { return; }
    const target = document.getElementById(fragment);
    for (let parent = target?.parentElement; parent; parent = parent.parentElement) { if (parent instanceof HTMLDetailsElement) parent.open = true; }
    if (target instanceof HTMLDetailsElement) target.open = true;
    target?.scrollIntoView?.({ block: 'start' });
    target?.focus({ preventScroll: true });
  }, [activeTab, location.hash, state.status]);
  if (state.status !== 'ready') return state.fallback;
  const sections = state.sections;
  const { payPeriod, companyId, returnTo } = sections.processing;
  const route = (tab: 'work' | 'checks' | 'reports' | 'activity', hash = '') => `${payRunPath(companyId, payPeriod.id, tab, { returnTo })}${hash}`;
  const held = (payPeriod.time_tracking?.linked_aire_records || []).reduce((sum, record) => sum + (record.payable_line_status?.held.entry_count || 0), 0);
  const preparedChecks = sections.processing.payrollItems.filter(item => !item.voided && item.effective_payment_delivery_method !== 'direct_deposit' && Number(item.net_pay) > 0 && ['prepared', 'printed'].includes(item.check_status || '')).length;
  const attention = [
    ...(payPeriod.intake_stale_at ? [{ text: 'Source changed · review required', href: route('work', '#payroll-blockers') }] : []),
    ...(sections.feedback.savedImportReloadRequired ? [{ text: 'Reload saved source hours before processing', href: route('work', '#payroll-feedback') }] : []),
    ...(sections.summary.hasCorrectionPayBasisHold ? [{ text: 'Review retained correction pay setup', href: route('work', '#pay-basis-hold') }] : []),
    ...(payPeriod.correction_status === 'voided' ? [{ text: 'Review voided payroll and correction history', href: route('activity', '#payroll-corrections') }] : []),
    ...(sections.processing.hasPendingCalculationChanges ? [{ text: 'Recalculate to include your changes', href: route('work', '#payroll-blockers') }] : []),
    ...(sections.feedback.calculationFailures.length ? [{ text: `${sections.feedback.calculationFailures.length} calculation errors`, href: route('work', '#payroll-calculation-issues') }] : []),
    ...(payPeriod.client_payroll_approval_required && payPeriod.payroll_review?.status !== 'approved' ? [{ text: 'Client approval pending', href: route('work', '#payroll-commit') }] : []),
    ...(held ? [{ text: `${held} held entries outside this payroll`, href: route('work', '#time-tracking-sync') }] : []),
    ...(payPeriod.status === 'committed' && payPeriod.correction_status !== 'voided' ? [{ text: preparedChecks ? `${preparedChecks} check${preparedChecks === 1 ? '' : 's'} prepared, not issued` : 'Review check preparation and payment delivery', href: route('checks') }] : []),
    ...(payPeriod.parallel_run ? [{ text: 'Parallel comparison · cannot commit', href: route('activity') }] : []),
  ];
  return <div>
    <SourceCoverageDialog {...sections.coverage} />
    <PayRunReviewDialogs {...sections.reviewDialogs} />
    <RefreshSetupDialog {...sections.refreshDialog} />
    <PayRunRecordHeader payRun={payPeriod} client={activeCompany?.name} returnTo={returnTo}
      attention={attention.length ? attention.map((item, index) => <span key={item.text}>{index > 0 && ' · '}<Link className="underline decoration-neutral-300 underline-offset-4 hover:text-primary-800" to={item.href}>{item.text}</Link></span>) : <Link className="underline decoration-neutral-300 underline-offset-4" to={route('work', needsSourceCoverageAcknowledgement(payPeriod) ? '#time-tracking-sync' : '#payroll-results')}>{needsSourceCoverageAcknowledgement(payPeriod) ? 'Time tracking hours have not been added' : payPeriod.status === 'draft' ? 'Enter or review pay, then calculate' : 'Review employee pay before the next step'}</Link>}
      actions={<PayRunProcessingActions {...sections.processing} />} totals={<PayRunSummary {...sections.summary} />} />
    {props.navigation}
    <h2 className="sr-only">{activeTab === 'checks' ? 'Checks and payments' : activeTab === 'reports' ? 'Reports' : activeTab === 'activity' ? 'Activity' : 'Payroll'}</h2>
    <div className="min-h-[24rem] space-y-4 p-4 sm:p-6 lg:px-8">
      <section hidden={activeTab !== 'work'} aria-label="Payroll workspace" className="space-y-6">
        <PayRunSteps sections={sections} />
        {payPeriod.status === 'committed' && <p className="text-sm text-neutral-700">Check preparation, tax checks, payment holds and manual reconciliation: <Link className="font-semibold text-primary-700 underline" to={route('checks')}>Checks &amp; payments</Link></p>}
        {payPeriod.status !== 'draft' && <p className="text-sm text-neutral-700">Payroll reports, final record, sign-off and liabilities: <Link className="font-semibold text-primary-700 underline" to={route('reports')}>Reports</Link></p>}
        {(payPeriod.notes || payPeriod.correction_status || payPeriod.run_purpose === 'correction') && <p className="text-sm text-neutral-700">Run notes, history and corrections: <Link className="font-semibold text-primary-700 underline" to={route('activity')}>Activity</Link></p>}
      </section>
      <section hidden={activeTab !== 'checks'} aria-label="Checks and payments workspace" className="space-y-6">
        {props.checksContent?.({ refreshToken: sections.checks.checkPrintRefreshToken, searchTerm: sections.checks.searchTerm, onChecksLoaded: sections.nonEmployeeChecks.handleNonEmployeeChecksLoaded }) ?? <><PayRunChecks {...sections.checks} /><PayRunNonEmployeeChecks {...sections.nonEmployeeChecks} /><PayRunCheckPrintDialog {...sections.printDialog} /></>}
        <PayRunSupportingDetails {...sections.supporting} section="checks" />
      </section>
      <section hidden={activeTab !== 'reports'} aria-label="Reports workspace" className="space-y-6">
        <PayRunReports {...sections.reports} />
        <PayRunLiabilities {...sections.liabilities} />
        {payPeriod.status === 'draft' && <p className="text-sm text-neutral-600">Reports are available after payroll is calculated.</p>}
      </section>
      <section hidden={activeTab !== 'activity'} aria-label="Activity workspace" className="space-y-6">
        <PayRunMetadata {...sections.metadata} />
        <PayRunSupportingDetails {...sections.supporting} section="activity" />
        {activeTab === 'activity' && props.activityContent}
        <PayRunLinkedCorrections {...sections.linkedCorrections} />
        <PayRunTimecardHistory {...sections.timecardHistory} />
        <div id="payroll-corrections" tabIndex={-1} className="scroll-mt-4"><PayRunCorrections {...sections.corrections} /></div>
      </section>
    </div>
    <PayRunDialogs {...sections.dialogs} />
  </div>;
}
