import { Navigate, useLocation, useParams } from 'react-router';
import { useCompany } from '@/contexts/CompanyContext';
import {
  employeeEditPath,
  employeePath,
  employeesPath,
  newEmployeePath,
  payRunPath,
  payRunsPath,
} from '@/lib/routes';

type LegacyDestination = 'employees' | 'new-employee' | 'employee' | 'pay-runs' | 'pay-run';

export function LegacyCompanyRedirect({ destination, clientMode = false }: { destination: LegacyDestination; clientMode?: boolean }) {
  const { id } = useParams<{ id: string }>();
  const location = useLocation();
  const { activeCompanyId, loading } = useCompany();

  if (loading || !activeCompanyId) {
    return (
      <div className="flex min-h-[320px] items-center justify-center" role="status">
        <span className="text-sm font-semibold text-neutral-500">Resolving client workspace…</span>
      </div>
    );
  }

  const recordId = Number(id);
  const returnTo = `${location.pathname}${location.search}`;
  let target = employeesPath(activeCompanyId, location.search);

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
