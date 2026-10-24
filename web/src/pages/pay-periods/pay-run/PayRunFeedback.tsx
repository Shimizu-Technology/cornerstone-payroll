

import { Alert } from '@/components/ui/alert';

import { PayrollCalculationIssues } from '@/components/payroll/PayrollCalculationIssues';

import { Button } from '@/components/ui/button';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunFeedback({
  calculationFailures,
  calculationNotice,
  calendarRefreshError,
  companyId,
  currentPath,
  employees,
  error,
  payPeriod,
  payrollItems,
  processing,
  reloadSavedSourceImport,
  savedImportReloadRequired,
  timeTrackingImportOpen,
  worksheetRefreshWarning
}: PayRunSectionProps<'feedback'>) {
  return (<>
{error && <Alert tone="error">
        <p>{error}</p>
        {calculationFailures.length > 0 && <Button variant="outline" className="mt-3" onClick={() => {
          const section = document.getElementById('payroll-calculation-issues');
          section?.scrollIntoView({ block: 'start' });
          section?.focus({ preventScroll: true });
        }}>Review affected employees</Button>}
      </Alert>}
{calculationNotice && <Alert tone="success">{calculationNotice}</Alert>}
{savedImportReloadRequired && <Alert>
        <p>Saved source hours need a current payroll reload before processing. The last saved payroll remains visible for context.</p>
        <Button className="mt-3 min-h-11" variant="outline" disabled={processing || timeTrackingImportOpen} onClick={() => void reloadSavedSourceImport()}>Reload saved payroll</Button>
      </Alert>}
{calendarRefreshError && <Alert>{calendarRefreshError}</Alert>}
{worksheetRefreshWarning && <Alert>{worksheetRefreshWarning}</Alert>}
{calculationFailures.length > 0 && <PayrollCalculationIssues failures={calculationFailures} companyId={companyId} year={Number(payPeriod.pay_date.slice(0, 4))} returnTo={currentPath} names={new Map([
        ...payrollItems.map((item): [number, string] => [item.employee_id, item.employee_name || `Employee #${item.employee_id}`]),
        ...employees.map((employee): [number, string] => [employee.id, `${employee.first_name} ${employee.last_name}`]),
      ])} />}
  </>);
}
