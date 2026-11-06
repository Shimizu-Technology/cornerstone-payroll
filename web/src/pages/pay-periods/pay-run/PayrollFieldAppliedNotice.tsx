

import type { ReactElement } from 'react';

import { formatCurrency } from '@/lib/utils';

import type { PayPeriodPayrollFieldAssignment } from '@/types';
import { payrollFieldAmountsEqual } from './payRunSupport';

export function PayrollFieldAppliedNotice({ assignment }: { assignment: PayPeriodPayrollFieldAssignment }): ReactElement | null {
  if (assignment.requested_amount == null || assignment.current_amount == null || payrollFieldAmountsEqual(assignment.requested_amount, assignment.current_amount)) return null;
  return <p className="mt-1 text-xs leading-5 text-warning-800">Last applied {formatCurrency(assignment.current_amount)} after limits. The input shows the requested amount.</p>;
}
