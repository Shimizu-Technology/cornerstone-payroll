import { useEffect, useState, type ReactElement } from 'react';
import { ChevronLeft } from 'lucide-react';
import { Link, useLocation } from 'react-router';
import { useBrand, useEmployeeAuth } from './contexts';
import { CantSignIn } from './help';
import { useDocumentTitle } from './hooks';
import { clearSigningOut, redirectTarget } from './routing';
import { forgetInviteToken } from './signupState';
import { BrandMark, DemoPill, EmpButtonLink } from './ui';

function firstTimeLine(name: string | null): string {
  return `First time here? Your manager${name ? ` at ${name}` : ''} will send you a link to set up your account.`;
}

function SetUpLink(): ReactElement {
  return (
    <p className="text-center text-[0.95rem]">
      Have a printed sign-up code? <Link to="/activate" className="emp-link-inline emp-link-standalone">Set up your account</Link>
    </p>
  );
}

export function WelcomeScreen(): ReactElement {
  const brand = useBrand();
  useDocumentTitle('Welcome');
  useEffect(() => {
    clearSigningOut();
    // Back to Welcome leaves any sign-up behind.
    forgetInviteToken();
  }, []);
  return (
    <main className="emp-auth">
      <div className="emp-auth-grow">
        <BrandMark size="lg" />
        {!brand.isFallback && brand.demo && (
          <p className="flex flex-wrap items-center gap-2 font-display text-[1.06rem] font-bold text-neutral-900">
            <span className="min-w-0 [overflow-wrap:anywhere]">{brand.name}</span>
            <DemoPill />
          </p>
        )}
        <h1 className="emp-h1">Your pay, on your phone</h1>
        <p className="emp-lead">
          {brand.isFallback ? 'See your pay stubs and tax forms any time.' : `See your pay stubs and tax forms from ${brand.name} any time.`}
        </p>
      </div>
      <div className="space-y-4">
        <EmpButtonLink to="/sign-in" block>Sign in</EmpButtonLink>
        <p className="text-center text-[0.88rem] text-neutral-600">{firstTimeLine(brand.isFallback ? null : brand.name)}</p>
        <SetUpLink />
        <CantSignIn />
      </div>
    </main>
  );
}

export function SignInScreen(): ReactElement {
  const brand = useBrand();
  useDocumentTitle('Sign in');
  const { SignInForm } = useEmployeeAuth();
  const location = useLocation();
  // Read once: Clerk's hash steps (such as the new-device code at
  // #/client-trust) replace the history entry and drop its state, which
  // would otherwise send the person to Home instead of back to an invite.
  const [redirectTo] = useState(() => redirectTarget(location.state));
  return (
    <main className="emp-auth emp-auth-top">
      <div className="emp-auth-bar">
        <Link to="/" className="emp-back" onClick={forgetInviteToken}>
          <ChevronLeft aria-hidden="true" className="size-[26px]" />
          Back
        </Link>
        <span className="flex min-w-0 items-center gap-2">
          <BrandMark />
          <span className="min-w-0 [overflow-wrap:anywhere] font-display text-[1.06rem] font-bold leading-tight">{brand.name}</span>
          {brand.demo && <DemoPill />}
        </span>
      </div>
      <SignInForm redirectTo={redirectTo} />
      <div className="mt-4 space-y-4">
        <p className="text-center text-[0.88rem] text-neutral-600">{firstTimeLine(brand.isFallback ? null : brand.name)}</p>
        <SetUpLink />
        <CantSignIn />
      </div>
    </main>
  );
}
