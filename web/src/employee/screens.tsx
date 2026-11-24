import { useEffect, type ReactElement } from 'react';
import { Banknote, CalendarDays, ChevronLeft, CircleHelp, FileText, House, LogOut, UserRound } from 'lucide-react';
import { Link, useLocation } from 'react-router';
import { askManager } from './brand';
import { useBrand, useEmployeeAuth } from './contexts';
import { useDocumentTitle, useSignOut } from './hooks';
import { clearSigningOut, redirectTarget } from './routing';
import { focusHeadingOnNextScreen } from './focus';
import { HideAmountsToggle } from './HideAmounts';
import { BrandMark, Card, EmpButton, EmpButtonLink, Page, Placeholder } from './ui';

function firstTimeLine(name: string | null): string {
  return `First time here? Your manager${name ? ` at ${name}` : ''} will send you a link to set up your account.`;
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
      <p className="mt-4 text-center text-[0.88rem] text-neutral-600">{firstTimeLine(brand.isFallback ? null : brand.name)}</p>
    </main>
  );
}

function QuestionsCard(): ReactElement {
  const brand = useBrand();
  return (
    <Card title="Questions about your pay?">
      <p className="text-neutral-700">{askManager(brand)}</p>
      <Link to="/help" className="emp-link mt-2" onClick={focusHeadingOnNextScreen}>Go to Help</Link>
    </Card>
  );
}

/** Desktop: latest pay and recent pay on the left, the rest on the right. Phone: one column. */
export function HomeTab(): ReactElement {
  return (
    <Page title="Welcome">
      <div className="emp-home-grid">
        <div className="emp-column">
          <Card title="Latest pay" action={<HideAmountsToggle />}>
            <Placeholder icon={House} title="Your latest pay will show here">
              <p>You'll see your take-home pay and your pay stub here as soon as they're added.</p>
            </Placeholder>
          </Card>
          <Card title="Recent pay">
            <Placeholder icon={Banknote} title="Your recent paychecks will show here">
              <p>Each one links to its pay stub.</p>
            </Placeholder>
          </Card>
        </div>
        <div className="emp-column emp-wide-only">
          <Card title="This year so far">
            <Placeholder icon={CalendarDays} title="Your totals for the year will show here">
              <p>Take-home pay and pay before taxes, added up.</p>
            </Placeholder>
          </Card>
          <QuestionsCard />
        </div>
      </div>
    </Page>
  );
}

/** Desktop: the list on the left and the selected stub on the right. Phone: the list. */
export function PayTab(): ReactElement {
  return (
    <Page title="Pay stubs" actions={<HideAmountsToggle />}>
      <div className="emp-pay-grid">
        <Card title="Your pay">
          <Placeholder icon={Banknote} title="Your pay stubs will show here">
            <p>Each paycheck will be listed here with its pay stub.</p>
          </Placeholder>
        </Card>
        <Card title="Pay stub" className="emp-wide-only">
          <Placeholder icon={FileText} title="Pay stub details will show here">
            <p>Pick a paycheck to see what you earned, what was taken out and your take-home pay.</p>
          </Placeholder>
        </Card>
      </div>
    </Page>
  );
}

export function TaxesTab(): ReactElement {
  return (
    <Page title="Tax forms">
      <div className="emp-cards-grid">
        <Card>
          <Placeholder icon={FileText} title="Your tax forms will show here">
            <p>Your W-2GU will be here when it's ready. You'll still get a paper copy, the same way as other years.</p>
          </Placeholder>
        </Card>
      </div>
    </Page>
  );
}

export function MyInfoTab(): ReactElement {
  const signOut = useSignOut();
  return (
    <Page title="My info">
      <div className="emp-cards-grid">
        <Card>
          <Placeholder icon={UserRound} title="Your contact details will show here">
            <p>Your phone number, email and home address will be listed here.</p>
          </Placeholder>
        </Card>
      </div>
      <EmpButton block variant="secondary" className="emp-narrow-button" onClick={signOut}>
        <LogOut aria-hidden="true" className="size-6" />
        Sign out
      </EmpButton>
    </Page>
  );
}

/**
 * Each client's managers answer their employees first, so with no contacts set
 * up yet this points to the manager and never to Cornerstone (UX audit, Help).
 */
export function HelpTab(): ReactElement {
  const brand = useBrand();
  return (
    <Page title="Help">
      <div className="emp-cards-grid">
        <Card>
          <Placeholder icon={CircleHelp} title="Questions about your pay or this app?">
            <p>{askManager(brand)}</p>
          </Placeholder>
        </Card>
      </div>
    </Page>
  );
}
