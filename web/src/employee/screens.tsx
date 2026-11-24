import { useEffect, type ReactElement } from 'react';
import { ChevronLeft } from 'lucide-react';
import { Link, useLocation } from 'react-router';
import { useBrand, useEmployeeAuth } from './contexts';
import { CantSignIn } from './help';
import { useDocumentTitle } from './hooks';
import { clearSigningOut, redirectTarget } from './routing';
import { BrandMark, EmpButtonLink } from './ui';

function firstTimeLine(name: string | null): string {
  return `First time here? Your manager${name ? ` at ${name}` : ''} will send you a link to set up your account.`;
}

function SetUpLink(): ReactElement {
  return (
    <p className="text-center text-[0.95rem]">
      Have a printed sign-up code? <Link to="/sign-up" className="emp-link-inline">Set up your account</Link>
    </p>
  );
}

export function WelcomeScreen(): ReactElement {
  const brand = useBrand();
  useDocumentTitle('Welcome');
  useEffect(() => clearSigningOut(), []);
  return (
    <main className="emp-auth">
      <div className="emp-auth-grow">
        <BrandMark size="lg" />
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
  return (
    <main className="emp-auth emp-auth-top">
      <div className="emp-auth-bar">
        <Link to="/" className="emp-back">
          <ChevronLeft aria-hidden="true" className="size-[26px]" />
          Back
        </Link>
        <span className="flex min-w-0 items-center gap-2">
          <BrandMark />
          <span className="min-w-0 break-words font-display text-[1.06rem] font-bold leading-tight">{brand.name}</span>
        </span>
      </div>
      <SignInForm redirectTo={redirectTarget(location.state)} />
      <div className="mt-4 space-y-4">
        <p className="text-center text-[0.88rem] text-neutral-600">{firstTimeLine(brand.isFallback ? null : brand.name)}</p>
        <SetUpLink />
        <CantSignIn />
      </div>
    </main>
  );
}
