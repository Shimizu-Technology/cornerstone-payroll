import { Link } from 'react-router';
import { useOptionalAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { employeeAppSwitchPath } from '@/lib/routes';

const linkClass = 'inline-flex min-h-11 items-center font-semibold text-primary-800 underline underline-offset-2 [overflow-wrap:anywhere]';

/**
 * The next step when part of the employee app is off: a link to the switch for
 * people who can change it, otherwise who to ask. A company the switch can't
 * turn on (an inactive client or a practice copy, by the API's
 * employee_app_switch_eligible rule) says so instead of promising a step.
 */
export function EmployeeAppTurnOnStep({ companyId, audience }: { companyId: number; audience: 'admin' | 'client' }) {
  const auth = useOptionalAuth();
  const { companies } = useCompany();
  const company = companies.find((candidate) => candidate.id === companyId);
  // Only a loaded company the API marked ineligible withholds the step; the
  // switch page itself still lists its own failing checks.
  if (company && company.employee_app_switch_eligible === false) {
    if (!company.active) return <>{company.name} is inactive, so the employee app can't be turned on for it.</>;
    if (company.test_workspace) return <>The employee app can't be turned on in a practice copy.</>;
    return <>The employee app can't be turned on for {company.name}.</>;
  }
  if (audience === 'client') return <>Cornerstone turns this on. Ask your Cornerstone contact if you'd like to start.</>;
  if (auth?.hasCapability('manage_employee_app_switch')) {
    return <Link className={linkClass} to={employeeAppSwitchPath(companyId)}>Turn it on in the employee app switch</Link>;
  }
  return <>Ask an admin with access to the employee app switch to turn it on.</>;
}
