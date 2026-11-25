import { Link } from 'react-router';
import { useOptionalAuth } from '@/contexts/AuthContext';
import { employeeAppSwitchPath } from '@/lib/routes';

const linkClass = 'inline-flex min-h-11 items-center font-semibold text-primary-800 underline underline-offset-2 [overflow-wrap:anywhere]';

/**
 * The next step when part of the employee app is off: a link to the switch for
 * people who can change it, otherwise who to ask.
 */
export function EmployeeAppTurnOnStep({ companyId, audience }: { companyId: number; audience: 'admin' | 'client' }) {
  const auth = useOptionalAuth();
  if (audience === 'client') return <>Cornerstone turns this on. Ask your Cornerstone contact if you'd like to start.</>;
  if (auth?.hasCapability('manage_employee_app_switch')) {
    return <Link className={linkClass} to={employeeAppSwitchPath(companyId)}>Turn it on in the employee app switch</Link>;
  }
  return <>Ask an admin with access to the employee app switch to turn it on.</>;
}
