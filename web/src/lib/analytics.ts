import posthog from 'posthog-js';
import { isPostHogEnabled } from '@/providers/PostHogProvider';

function capture(event: string, properties?: Record<string, unknown>) {
  if (isPostHogEnabled && !import.meta.env.DEV) {
    posthog.capture(event, properties);
  }
}

export const analytics = {
  payrollCalculated: (payPeriodId: number, employeeCount: number) =>
    capture('payroll_calculated', { pay_period_id: payPeriodId, employee_count: employeeCount }),

  payrollApproved: (payPeriodId: number) =>
    capture('payroll_approved', { pay_period_id: payPeriodId }),

  payrollCommitted: (payPeriodId: number) =>
    capture('payroll_committed', { pay_period_id: payPeriodId }),

  checksDownloaded: (payPeriodId: number, count: number) =>
    capture('checks_downloaded', { pay_period_id: payPeriodId, check_count: count }),

  checksPrinted: (payPeriodId: number, count: number) =>
    capture('checks_printed', { pay_period_id: payPeriodId, check_count: count }),

  reportGenerated: (reportType: string, payPeriodId?: number) =>
    capture('report_generated', { report_type: reportType, pay_period_id: payPeriodId }),

  employeeCreated: () => capture('employee_created'),

  timecardUploaded: (fileType: string) =>
    capture('timecard_uploaded', { file_type: fileType }),

  timecardOcrApplied: (payPeriodId: number, entryCount: number) =>
    capture('timecard_ocr_applied', { pay_period_id: payPeriodId, entry_count: entryCount }),

  companySwitch: (companyId: number) =>
    capture('company_switched', { company_id: companyId }),
};
