import type { ReactElement } from 'react';
import { UserProfile } from '@clerk/react';
import { ShieldCheck } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { useAuth } from '@/contexts/AuthContext';

export function AccountSecurity(): ReactElement {
  const { user } = useAuth();
  const clerkConfigured = Boolean(import.meta.env.VITE_CLERK_PUBLISHABLE_KEY);

  return (
    <div>
      <Header
        title="Account & security"
        description="Manage your sign-in methods, authenticator app, and backup codes."
        contextLabel="Account"
        contextValue={user?.email || user?.name || 'Your account'}
        mobileSticky={false}
      />
      <div className="mx-auto max-w-4xl space-y-6 p-4 sm:p-6 lg:p-8">
        <div className="flex items-start gap-3 rounded-2xl border border-primary-100 bg-primary-50/60 p-4 text-sm text-neutral-800">
          <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-primary-700" aria-hidden="true" />
          <div className="min-w-0 space-y-1">
            <p className="font-semibold text-neutral-900">Setting up two-step sign-in</p>
            <p className="leading-6 text-neutral-700">
              Open <span className="font-semibold text-neutral-900">Security &rarr; Two-step verification</span> below
              to add an authenticator app, then save your backup codes somewhere safe (not only on the same phone).
              Need help? Ask your Cornerstone administrator.
            </p>
          </div>
        </div>

        {clerkConfigured ? (
          <div className="min-w-0 overflow-x-auto">
            <UserProfile
              routing="hash"
              appearance={{
                elements: {
                  rootBox: 'w-full max-w-full',
                  cardBox: 'w-full max-w-full shadow-none border border-neutral-200 rounded-2xl',
                },
              }}
            />
          </div>
        ) : (
          <Card>
            <CardHeader>
              <CardTitle>Account &amp; security settings</CardTitle>
              <CardDescription>
                Password, authenticator app, and backup code settings are managed through Clerk when sign-in is configured.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-2 text-sm text-neutral-700">
              <p>
                <span className="font-semibold text-neutral-900">Signed in as:</span>{' '}
                {user?.name || 'User'}{user?.email ? ` (${user.email})` : ''}
              </p>
              <p className="text-xs text-neutral-600">
                Clerk is not enabled in this local development session, so the embedded account security panel is hidden.
              </p>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
