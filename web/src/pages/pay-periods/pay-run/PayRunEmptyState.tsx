

import { Link } from 'react-router';
import { UserPlus } from 'lucide-react';

import { newEmployeePath } from '@/lib/routes';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunEmptyState({
  companyId,
  currentPath,
  employees,
  isDraft,
  payrollItems
}: PayRunSectionProps<'empty'>) {
  return (<>
{isDraft && payrollItems.length === 0 && employees.length === 0 && (
          <div className="flex flex-col items-center p-12 text-center text-neutral-600">
            <UserPlus className="mb-4 h-8 w-8 text-neutral-600" aria-hidden="true" />
            <p>No employees are eligible for this pay period. Check hire and termination dates before running payroll.</p>
            <Link
              className="mt-4 inline-flex min-h-11 items-center rounded-full bg-primary-700 px-4 py-2 text-sm font-semibold text-white transition hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
              to={newEmployeePath(companyId, { returnTo: currentPath })}
            >
              <UserPlus className="mr-2 h-4 w-4" aria-hidden="true" />
              Add employee
            </Link>
          </div>
        )}
  </>);
}
