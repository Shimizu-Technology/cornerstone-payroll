import { usePayRunController } from './pay-periods/pay-run/usePayRunController';
import type { PayPeriodDetailProps } from './pay-periods/pay-run/payRunSupport';
import { SourceCoverageDialog } from './pay-periods/pay-run/SourceCoverageDialog';
import { PayRunReviewDialogs } from './pay-periods/pay-run/PayRunReviewDialogs';
import { PayRunSummary } from './pay-periods/pay-run/PayRunSummary';
import { PayRunProcessingActions } from './pay-periods/pay-run/PayRunProcessingActions';
import { PayRunFeedback } from './pay-periods/pay-run/PayRunFeedback';
import { PayRunBlockers } from './pay-periods/pay-run/PayRunBlockers';
import { PayRunSourceCheckpoint } from './pay-periods/pay-run/PayRunSourceCheckpoint';
import { PayRunMetadata } from './pay-periods/pay-run/PayRunMetadata';
import { RefreshSetupDialog } from './pay-periods/pay-run/RefreshSetupDialog';
import { PayRunLoanInputs } from './pay-periods/pay-run/PayRunLoanInputs';
import { PayRunComparison } from './pay-periods/pay-run/PayRunComparison';
import { PayRunRoster } from './pay-periods/pay-run/PayRunRoster';
import { PayRunHoursWorksheet } from './pay-periods/pay-run/PayRunHoursWorksheet';
import { PayRunEmployeeResults } from './pay-periods/pay-run/PayRunEmployeeResults';
import { PayRunEmployerTaxes } from './pay-periods/pay-run/PayRunEmployerTaxes';
import { PayRunLiabilities } from './pay-periods/pay-run/PayRunLiabilities';
import { PayRunEmptyState } from './pay-periods/pay-run/PayRunEmptyState';
import { PayRunLinkedCorrections } from './pay-periods/pay-run/PayRunLinkedCorrections';
import { PayRunChecks } from './pay-periods/pay-run/PayRunChecks';
import { PayRunSupportingDetails } from './pay-periods/pay-run/PayRunSupportingDetails';
import { PayRunTimecardOcr } from './pay-periods/pay-run/PayRunTimecardOcr';
import { PayRunNonEmployeeChecks } from './pay-periods/pay-run/PayRunNonEmployeeChecks';
import { PayRunCheckPrintDialog } from './pay-periods/pay-run/PayRunCheckPrintDialog';
import { PayRunReports } from './pay-periods/pay-run/PayRunReports';
import { PayRunTimecardHistory } from './pay-periods/pay-run/PayRunTimecardHistory';
import { PayRunCorrections } from './pay-periods/pay-run/PayRunCorrections';
import { PayRunDialogs } from './pay-periods/pay-run/PayRunDialogs';

export function PayPeriodDetail(props: PayPeriodDetailProps) {
  const state = usePayRunController(props);
  if (state.status !== 'ready') return state.fallback;
  return (
    <div>
      <SourceCoverageDialog {...state.sections.coverage} />
      <PayRunReviewDialogs {...state.sections.reviewDialogs} />

      <h2 className="sr-only">Process payroll</h2>
      <PayRunSummary {...state.sections.summary} />
      <PayRunProcessingActions {...state.sections.processing} />

      <PayRunFeedback {...state.sections.feedback} />

      <div className="space-y-6">

        <PayRunBlockers {...state.sections.blockers} />

        <PayRunSourceCheckpoint {...state.sections.source} />

        {/* Status Bar */}
        <PayRunMetadata {...state.sections.metadata} />

        <RefreshSetupDialog {...state.sections.refreshDialog} />

        <PayRunLoanInputs {...state.sections.loans} />

        {/* Previous Period Comparison */}
        <PayRunComparison {...state.sections.comparison} />

        {/* Active employees remain available for a later adjustment without
            becoming payroll records for a period in which they earned nothing. */}
        <PayRunRoster {...state.sections.roster} />

        {/* Hours Input (Draft Mode) */}
        <PayRunHoursWorksheet {...state.sections.hours} />

        {/* Payroll Results Table (Calculated/Approved/Committed) */}
        <PayRunEmployeeResults {...state.sections.results} />

        {/* Employer Tax Obligations (Calculated/Approved/Committed) */}
        <PayRunEmployerTaxes {...state.sections.employerTaxes} />

        <PayRunLiabilities {...state.sections.liabilities} />

        {/* Empty state for draft */}
        <PayRunEmptyState {...state.sections.empty} />

        {/* Linked Corrections — surfaces supplemental periods that
             corrected this period (one-off corrective paychecks). */}
        <PayRunLinkedCorrections {...state.sections.linkedCorrections} />

        {/* When viewing a supplemental, link back to the original. */}

        {/* CPR-66: Checks Panel — only for committed pay periods */}
        <PayRunChecks {...state.sections.checks} />

        <PayRunSupportingDetails {...state.sections.supporting} />

        {/* Timecard OCR Panel — for draft pay periods */}
        <PayRunTimecardOcr {...state.sections.ocr} />

        {/* Non-Employee Checks — for committed pay periods */}
        <PayRunNonEmployeeChecks {...state.sections.nonEmployeeChecks} />

        <PayRunCheckPrintDialog {...state.sections.printDialog} />

        <PayRunReports {...state.sections.reports} />

        {/* Reports Download Panel — for calculated/approved/committed */}

        {/* Timecard History — read-only view for processed pay periods */}
        <PayRunTimecardHistory {...state.sections.timecardHistory} />

        {/* CPR-71: Correction Panel — committed and voided periods */}
        <PayRunCorrections {...state.sections.corrections} />

      </div>

      {/* Import Modal */}
      <PayRunDialogs {...state.sections.dialogs} />

      {/* Per-employee Corrective Paycheck Modal — only relevant on
          committed regular periods. */}

      {/* Replace Check (uncashed) Modal — used when the original check is
          in our possession (never distributed or returned uncashed) and
          the financial values need to change. Different from Correct
          (which leaves the original alone and adds a supplemental delta). */}

      {/* Payroll Item Edit Modal */}

    </div>
  );
}
