import type { ReactElement } from 'react';
import { Navigate, useLocation, useParams } from 'react-router';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { useCompany } from '@/contexts/CompanyContext';
import {
  employeeEditPath,
  employeePath,
  employeesPath,
  newEmployeePath,
  payRunPath,
  payRunsPath,
  safeInternalReturnPath,
} from '@/lib/routes';

type LegacyDestination = 'employees' | 'new-employee' | 'employee' | 'pay-runs' | 'pay-run';

interface LegacyCompanyRedirectProps {
  destination: LegacyDestination;
  clientMode?: boolean;
}

export function LegacyCompanyRedirect({ destination, clientMode = false }: LegacyCompanyRedirectProps): ReactElement {
  const { id } = useParams<{ id: string }>();
  const location = useLocation();
  const { activeCompanyId, loading } = useCompany();

  if (loading || !activeCompanyId) {
    return <WorkspaceLoader label="Resolving client workspace" minHeightClassName="min-h-[320px]" />;
  }

  const recordId = Number(id);
  const searchParams = new URLSearchParams(location.search);
  const employeeList = employeesPath(activeCompanyId);
  const payRunList = payRunsPath(activeCompanyId);
  const recordFallback = destination === 'pay-run' ? payRunList : employeeList;
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), recordFallback);
  let target = recordFallback;

  if (destination === 'employees') target = employeesPath(activeCompanyId, location.search);
  if (destination === 'new-employee') target = newEmployeePath(activeCompanyId, { returnTo });
  if (destination === 'employee' && Number.isInteger(recordId)) {
    target = clientMode
      ? employeeEditPath(activeCompanyId, recordId, { returnTo })
      : employeePath(activeCompanyId, recordId, 'overview', { returnTo });
  }
  if (destination === 'pay-runs') target = payRunsPath(activeCompanyId, location.search);
  if (destination === 'pay-run' && Number.isInteger(recordId)) {
    target = payRunPath(activeCompanyId, recordId, clientMode ? 'overview' : 'work', { returnTo });
  }

  return <Navigate to={target} replace />;
}
