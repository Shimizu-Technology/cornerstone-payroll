import { Show, SignIn, SignUp, useClerk } from '@clerk/react';
import { useState, type ComponentProps } from 'react';
import { Link, Navigate, useLocation } from 'react-router';
import { ShieldCheck, Clock3, Landmark } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { isMfaRequiredCode } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { AccountAccessNotice } from '@/components/auth/AccountAccessNotice';

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

const touchTarget = { minHeight: '44px' };
const actionLink = {
  ...touchTarget, display: 'inline-flex', alignItems: 'center',
  color: 'var(--color-primary-700)', '&:hover': { color: 'var(--color-primary-800)' },
};
const clerkAppearance: ComponentProps<typeof SignIn>['appearance'] = {
  elements: {
    rootBox: 'mx-auto w-full max-w-full',
    cardBox: 'w-full max-w-full',
    card: 'w-full max-w-full shadow-none border border-neutral-200 rounded-2xl',
    headerTitle: 'text-neutral-900',
    headerSubtitle: 'text-neutral-500',
    // Clerk's unlayered styles can take precedence over Tailwind utilities.
    socialButtonsBlockButton: { ...touchTarget, borderRadius: '0.75rem' },
    socialButtonsIconButton: touchTarget,
    alternativeMethodsBlockButton: touchTarget,
    formButtonPrimary: {
      ...touchTarget, borderRadius: '0.75rem', backgroundColor: 'var(--color-primary-600)',
      '&:hover': { backgroundColor: 'var(--color-primary-700)' },
    },
    formButtonReset: touchTarget,
    formFieldInput: { ...touchTarget, borderRadius: '0.75rem', fontSize: '16px' },
    formFieldInput__password: { paddingInlineEnd: '48px' },
    otpCodeFieldInput: { ...touchTarget, fontSize: '16px' },
    formFieldInputShowPasswordButton: { ...touchTarget, minWidth: '44px' },
    formFieldAction: actionLink,
    formResendCodeLink: actionLink,
    footerActionLink: actionLink,
    footerPagesLink: actionLink,
  },
};

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

/**
 * The recovery screen for an MFA denial, by its code: mfa_enrollment_required
 * means this login has no second factor yet, so it shows how to add one;
 * mfa_required means one is set up but this session skipped it, so it asks
 * for a fresh sign-in with the code instead.
 */
function MfaPrompt() {
  const { authProblem } = useAuth();
  return authProblem?.code === 'mfa_enrollment_required' ? <MfaEnrollmentPrompt /> : <MfaSignInPrompt />;
}

function MfaSignInPrompt() {
  const clerk = useClerk();
  const { authProblem, refreshUser, signOut } = useAuth();
  const [checking, setChecking] = useState(false);
  const [stillUnverified, setStillUnverified] = useState(false);

  async function checkVerification() {
    setChecking(true);
    setStillUnverified(false);
    try {
      try {
        await clerk.session?.reload?.();
      } catch {
        // Proceed to force-refresh the session token even if reload fails.
      }
      await refreshUser({ skipTokenCache: true });
      setStillUnverified(true);
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="mb-6 space-y-4 rounded-2xl border border-neutral-200 bg-neutral-50/60 p-4 sm:p-5">
      <div className="space-y-1.5">
        <h2 className="text-xl font-semibold text-neutral-900">Finish two-step sign-in</h2>
        <p className="text-sm leading-6 text-neutral-700">
          Two-step sign-in is already set up on this account, but this session hasn&rsquo;t finished it. Sign in again
          to open payroll.
        </p>
      </div>

      <ol className="list-decimal space-y-2 pl-5 text-sm leading-6 text-neutral-700">
        <li>
          Select <span className="font-semibold text-neutral-900">Sign out and sign back in</span>.
        </li>
        <li>
          When asked, enter the 6-digit code from your authenticator app, or one of your backup codes.
        </li>
      </ol>

      {stillUnverified && (
        <p role="status" className="rounded-xl border border-amber-300 bg-amber-50 px-3.5 py-2.5 text-sm text-amber-950">
          This session still hasn&rsquo;t finished two-step sign-in. Sign out and sign back in with your code.
        </p>
      )}

      {authProblem?.signOutFailed && (
        <p role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-3.5 py-2.5 text-sm text-danger-900">
          Could not sign out. Try again.
        </p>
      )}

      <div className="flex flex-wrap gap-2">
        <Button type="button" variant="primary" onClick={() => { void signOut().catch(() => undefined); }}>
          Sign out and sign back in
        </Button>
        <Button type="button" variant="outline" loading={checking} onClick={() => { void checkVerification(); }}>
          {checking ? 'Checking verification…' : 'Check verification'}
        </Button>
      </div>

      <p className="text-xs leading-5 text-neutral-600">
        Lost your authenticator app and backup codes? Ask your Cornerstone administrator.
      </p>
    </div>
  );
}

function MfaEnrollmentPrompt() {
  const clerk = useClerk();
  const { authProblem, refreshUser, signOut } = useAuth();
  const [checking, setChecking] = useState(false);
  const [openedSettings, setOpenedSettings] = useState(false);
  const [needsFreshSignIn, setNeedsFreshSignIn] = useState(false);

  async function checkVerification() {
    setChecking(true);
    setNeedsFreshSignIn(false);
    try {
      try {
        await clerk.session?.reload?.();
      } catch {
        // Proceed to force-refresh the session token even if reload fails.
      }
      await refreshUser({ skipTokenCache: true });
      // If MFA is now verified, Login redirects to /app and unmounts this prompt.
      // Staying mounted means the existing session still lacks a verified second factor
      // (for example, fva[1] remains -1 after first-time enrollment).
      setNeedsFreshSignIn(true);
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="mb-6 space-y-4 rounded-2xl border border-neutral-200 bg-neutral-50/60 p-4 sm:p-5">
      <div className="space-y-1.5">
        <h2 className="text-xl font-semibold text-neutral-900">Set up two-step sign-in</h2>
        <p className="text-sm leading-6 text-neutral-700">
          Cornerstone Payroll requires two-step sign-in on this account before you can open payroll, and this account
          doesn&rsquo;t have it set up yet.
        </p>
      </div>

      <ol className="list-decimal space-y-2 pl-5 text-sm leading-6 text-neutral-700">
        <li>
          Select <span className="font-semibold text-neutral-900">Open account settings</span>, go to{' '}
          <span className="font-semibold text-neutral-900">Security &rarr; Two-step verification</span>, and add an{' '}
          <span className="font-semibold text-neutral-900">authenticator app</span> (such as Google Authenticator,
          Microsoft Authenticator, or 1Password).
        </li>
        <li>
          <span className="font-semibold text-neutral-900">Save your backup codes</span> somewhere safe (such as a
          password manager or printed copy kept apart from your phone) before closing the setup screen.
        </li>
        <li>
          Select <span className="font-semibold text-neutral-900">Check verification</span> to refresh your session. If
          that does not clear this screen, select{' '}
          <span className="font-semibold text-neutral-900">Sign out and sign back in</span> and enter your 6-digit
          authenticator code.
        </li>
      </ol>

      {openedSettings && !needsFreshSignIn && (
        <p role="status" className="rounded-xl border border-primary-200 bg-primary-50/70 px-3.5 py-2.5 text-sm text-primary-950">
          Finished adding your authenticator app and saving your backup codes? Select{' '}
          <span className="font-semibold">Check verification</span> below, or sign out and sign back in with your
          6-digit code.
        </p>
      )}

      {needsFreshSignIn && (
        <div role="status" className="rounded-xl border border-amber-300 bg-amber-50 px-3.5 py-3 text-sm text-amber-950">
          <p className="font-semibold">This sign-in still needs a fresh two-step check.</p>
          <p className="mt-1 leading-6">
            Adding an authenticator app updates your account, but a session started before two-step verification stays
            unverified. Select <span className="font-semibold">Sign out and sign back in</span> below, then enter your
            6-digit authenticator code.
          </p>
        </div>
      )}

      {authProblem?.signOutFailed && (
        <p role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-3.5 py-2.5 text-sm text-danger-900">
          Could not sign out. Try again.
        </p>
      )}

      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          variant={needsFreshSignIn ? 'outline' : 'primary'}
          onClick={() => {
            setOpenedSettings(true);
            clerk.openUserProfile();
          }}
        >
          Open account settings
        </Button>
        <Button type="button" variant="outline" loading={checking} onClick={() => { void checkVerification(); }}>
          {checking ? 'Checking verification…' : 'Check verification'}
        </Button>
        <Button
          type="button"
          variant={needsFreshSignIn ? 'primary' : 'outline'}
          onClick={() => { void signOut().catch(() => undefined); }}
        >
          Sign out and sign back in
        </Button>
      </div>

      <p className="text-xs leading-5 text-neutral-600">
        Need help setting up your authenticator app or locked out without backup codes? Ask your Cornerstone
        administrator.
      </p>
    </div>
  );
}

export function Login() {
  const { isAuthenticated, isLoading, authProblem, refreshUser, signOut } = useAuth();
  const { search } = useLocation();

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

  const mfaRequired = authProblem?.status === 403 && isMfaRequiredCode(authProblem.code);
  const params = new URLSearchParams(search);
  // Clerk reads the ticket from the current URL. For sign_in it exchanges the
  // ticket in SignIn, and a completed Clerk session follows the normal auth path.
  const needsInviteSignUp = params.get('__clerk_status') === 'sign_up' && Boolean(params.get('__clerk_ticket'));
  const ClerkForm = needsInviteSignUp ? SignUp : SignIn;

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
              Cornerstone staff and client managers can use this workspace to review payroll, find reports, and keep
              employee records up to date.
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

          {/* Keep any access notice visible for a session that Clerk has already signed in. */}
          <Show when="signed-out">
            <ClerkForm
              routing="hash"
              signInUrl="/login"
              forceRedirectUrl="/app"
              appearance={clerkAppearance}
            />
          </Show>
          <div className="mt-3 flex flex-wrap items-center justify-center text-xs text-neutral-500">
            <Link to="/privacy" className="inline-flex min-h-11 items-center px-2 font-semibold hover:text-primary-700">Privacy Policy</Link>
            <span aria-hidden="true">·</span>
            <Link to="/terms" className="inline-flex min-h-11 items-center px-2 font-semibold hover:text-primary-700">Terms of Service</Link>
          </div>
        </section>
      </div>
    </div>
  );
}
