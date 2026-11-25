// "Sign-in & security" (/security): where an employee sets up two-step sign-in,
// the employee app's version of the staff Account & security page. It opens
// without the employee session, because once REQUIRE_MFA is on the API refuses
// pay screens (mfa_enrollment_required) until the second step is set up here.
import type { ReactElement } from 'react';
import { ShieldCheck } from 'lucide-react';
import { askManager } from './brand';
import { useBrand, useEmployeeAuth } from './contexts';
import { useDocumentTitle } from './hooks';
import { EmpButtonLink } from './ui';

export const SECURITY_PATH = '/security';

export function SecurityScreen(): ReactElement {
  useDocumentTitle('Sign-in & security');
  const brand = useBrand();
  const { AccountSecurityPanel } = useEmployeeAuth();
  return (
    <main className="emp-auth emp-auth-top emp-auth-wide space-y-4">
      <h1 className="emp-h1">Sign-in &amp; security</h1>
      <div className="emp-notice-inline flex items-start gap-3" role="note">
        <ShieldCheck aria-hidden="true" className="mt-0.5 size-6 shrink-0" />
        <div className="min-w-0 space-y-1">
          <p className="font-semibold">Setting up two-step sign-in</p>
          <p className="text-neutral-700">
            Open <span className="font-semibold">Security &rarr; Two-step verification</span> below and add an
            authenticator app. Then save your backup codes somewhere safe, not only on this phone.
          </p>
          <p className="text-neutral-700">
            When you're done, select <span className="font-semibold">Done</span>. If the app asks you to sign in
            again, sign out and sign back in with your new code.
          </p>
          <p className="text-neutral-600">{askManager(brand, 'Need help? Ask your manager')}</p>
        </div>
      </div>
      <div className="min-w-0 overflow-x-auto">
        <AccountSecurityPanel />
      </div>
      <EmpButtonLink block to="/">Done</EmpButtonLink>
    </main>
  );
}
