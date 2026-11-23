import { SignIn, SignedOut, useClerk } from '@clerk/clerk-react';
import { useState } from 'react';
import { Link, Navigate } from 'react-router';
import { ShieldCheck, Clock3, Landmark } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { AccountAccessNotice } from '@/components/auth/AccountAccessNotice';

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

const highlights = [
  {
    title: 'Guam-first payroll compliance',
    description: 'Built for W-2GU, Federal Form 941, and Guam filing workflows.',
    icon: <Landmark className="h-5 w-5" />,
  },
  {
    title: 'Secure operational controls',
    description: 'Role-based access and audit visibility for every workflow.',
    icon: <ShieldCheck className="h-5 w-5" />,
  },
  {
    title: 'Faster payroll execution',
    description: 'Run periods, print checks, and generate reports from one workspace.',
    icon: <Clock3 className="h-5 w-5" />,
  },
];

function MfaPrompt() {
  const { openUserProfile } = useClerk();
  const { authProblem, refreshUser, signOut } = useAuth();
  const [checking, setChecking] = useState(false);

  async function checkVerification() {
    setChecking(true);
    try {
      await refreshUser({ skipTokenCache: true });
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="mb-6 space-y-3 rounded-2xl border border-neutral-200 p-4">
      <h2 className="text-xl font-semibold text-neutral-900">Multi-factor authentication required</h2>
      <p className="text-sm text-neutral-700">
        Open your Clerk account settings and add a second factor under Security.
        Then sign out and sign back in with that factor.
      </p>
      {authProblem?.signOutFailed && (
        <p role="alert" className="text-sm text-neutral-700">Could not sign out. Try again.</p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button type="button" onClick={() => openUserProfile()}>
          Open account settings
        </Button>
        <Button type="button" variant="outline" onClick={() => { void signOut().catch(() => undefined); }}>
          Sign out
        </Button>
        <Button type="button" variant="outline" loading={checking} onClick={() => { void checkVerification(); }}>
          {checking ? 'Checking verification…' : 'Check verification'}
        </Button>
      </div>
    </div>
  );
}

export function Login() {
  const { isAuthenticated, isLoading, authProblem, refreshUser, signOut } = useAuth();

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-transparent">
        <p className="text-sm text-neutral-500">Loading Cornerstone Payroll...</p>
      </div>
    );
  }

  if (!clerkPubKey) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-transparent px-4">
        <Card className="w-full max-w-xl">
          <CardHeader className="text-center">
            <CardTitle className="text-xl">Cornerstone Payroll</CardTitle>
            <CardDescription>
              Clerk is not configured in <code>web/.env</code>. Add <code>VITE_CLERK_PUBLISHABLE_KEY</code> to enable sign in.
            </CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  if (isAuthenticated) {
    return <Navigate to="/app" replace />;
  }

  const mfaRequired = authProblem?.status === 403 && authProblem.code === 'mfa_required';

  return (
    <div className="min-h-screen bg-transparent px-3 py-4 sm:px-4 sm:py-10 lg:px-8">
      <div className="mx-auto grid w-full max-w-6xl gap-5 lg:grid-cols-2 lg:gap-8">
        <section className="relative order-2 overflow-hidden rounded-3xl border border-neutral-200/80 bg-gradient-to-br from-primary-950 via-primary-900 to-primary-700 p-5 text-white shadow-xl shadow-primary-900/20 sm:p-8 lg:order-1 lg:p-10">
          <div className="absolute right-0 top-0 h-56 w-56 translate-x-1/3 -translate-y-1/3 rounded-full bg-white/10 blur-2xl" />
          <div className="absolute bottom-0 left-0 h-52 w-52 -translate-x-1/4 translate-y-1/3 rounded-full bg-success-500/20 blur-2xl" />

          <div className="relative">
            <div className="mb-8 inline-flex items-center gap-3 rounded-2xl border border-white/20 bg-white/10 px-4 py-2 backdrop-blur-sm">
              <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-white/20 font-bold">CP</div>
              <span className="text-sm font-semibold tracking-tight">Cornerstone Payroll</span>
            </div>

            <h1 className="max-w-md text-3xl font-semibold leading-tight tracking-tight lg:text-4xl">
              Payroll operations built for Guam teams.
            </h1>
            <p className="mt-4 max-w-lg text-sm leading-relaxed text-primary-100 lg:text-base">
              A dedicated payroll workspace for Cornerstone Tax Services: company setup, employee records, pay periods,
              check printing, and year-end reporting.
            </p>

            <div className="mt-8 hidden space-y-4 sm:block lg:mt-10">
              {highlights.map((item) => (
                <div
                  key={item.title}
                  className="flex items-start gap-3 rounded-2xl border border-white/15 bg-white/10 p-4 backdrop-blur-sm"
                >
                  <div className="mt-0.5 rounded-lg bg-white/20 p-2 text-white">{item.icon}</div>
                  <div>
                    <p className="text-sm font-semibold">{item.title}</p>
                    <p className="mt-1 text-sm text-primary-100/95">{item.description}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="cornerstone-sign-in order-1 min-w-0 overflow-hidden rounded-3xl border border-neutral-200/80 bg-white/90 p-4 shadow-xl shadow-neutral-200/50 backdrop-blur-sm sm:p-6 lg:order-2 lg:p-8">
          {!mfaRequired && (
            <div className="mb-6">
              <p className="text-xs font-semibold uppercase tracking-[0.14em] text-primary-700">Welcome back</p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight text-neutral-900">Sign in to Cornerstone Payroll</h2>
              <p className="mt-2 text-sm text-neutral-500">Use your Cornerstone account to continue.</p>
            </div>
          )}

          {mfaRequired ? (
            <MfaPrompt />
          ) : authProblem && (
            <AccountAccessNotice
              className="mb-6"
              problem={authProblem}
              onRetry={authProblem.status !== 401 || authProblem.signOutFailed ? () => { void refreshUser().catch(() => undefined); } : undefined}
              onSignOut={authProblem.status === 401 ? undefined : () => { void signOut(); }}
            />
          )}

          {/* An already-signed-in Clerk session (e.g. an invite accepted during
              maintenance) keeps the notice up; mounting SignIn would bounce to /app. */}
          <SignedOut>
          <SignIn
            routing="hash"
            forceRedirectUrl="/app"
            fallbackRedirectUrl="/app"
            appearance={{
              elements: {
                rootBox: 'mx-auto w-full max-w-full',
                cardBox: 'w-full max-w-full',
                card: 'w-full max-w-full shadow-none border border-neutral-200 rounded-2xl',
                headerTitle: 'text-neutral-900',
                headerSubtitle: 'text-neutral-500',
                socialButtonsBlockButton:
                  'rounded-xl border-neutral-200 hover:bg-neutral-50 transition-colors',
                formButtonPrimary:
                  'rounded-xl bg-primary-600 hover:bg-primary-700 text-white shadow-sm transition-colors',
                formFieldInput:
                  'rounded-xl border-neutral-300 focus:border-primary-500 focus:ring-primary-200',
                footerActionLink: 'text-primary-700 hover:text-primary-800',
              },
            }}
          />
          </SignedOut>
          <p className="mt-6 text-center text-xs text-neutral-500">
            <Link to="/privacy" className="font-semibold hover:text-primary-700">Privacy Policy</Link>
            <span aria-hidden="true" className="mx-2">·</span>
            <Link to="/terms" className="font-semibold hover:text-primary-700">Terms of Service</Link>
          </p>
        </section>
      </div>
    </div>
  );
}
