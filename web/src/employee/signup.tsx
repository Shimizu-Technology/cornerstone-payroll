// Sign-up, claim and reactivation (M4-2), on the routes the API's invite
// links use (EmployeeLinks::AppUrl):
// - /activate: a new person. The invite link's token (or a printed code),
//   date of birth and SSN last 4, then their email, sent as one check. Then
//   Clerk's own sign-up opens from the invitation URL the API returns, on
//   /sign-up, and /sign-up/done binds the new login (/auth/me).
// - /claim: someone who already has a login signs in, then the same check
//   plus step-up adds the employee access to that login.
// - /reactivate: a rehired employee's old login, the same way.
// Every failed check shows one message. None says whether a person, an email
// or an invite exists, and a paused invite looks the same as a wrong detail.
import { useEffect, useMemo, useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { ChevronLeft } from 'lucide-react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router';
import { createEmployeeApi, EmployeeApiError, StepUpCancelledError } from './api';
import { askManager } from './brand';
import { API_BASE_URL } from './config';
import { useEmployeeTerms, type EmployeeTerms } from './terms';
import type { IdentityCheck } from './contracts';
import { useBrand, useEmployeeAuth } from './contexts';
import { CantSignIn } from './help';
import { useDocumentTitle, useSignOut } from './hooks';
import { PAPERLESS_PATH } from './paperlessState';
import { birthDate, currentInviteToken, forgetInviteToken, normalizeCode, rateLimitedText, takeInviteToken } from './signupState';
import { BrandMark, EmpButton, Field, FormMessage } from './ui';

// ---------- Identity fields ----------

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

interface IdentityDraft {
  code: string;
  month: string;
  day: string;
  year: string;
  ssnLast4: string;
}

const EMPTY_DRAFT: IdentityDraft = { code: '', month: '', day: '', year: '', ssnLast4: '' };

type IdentityProblems = Partial<Record<'code' | 'birth' | 'ssn', string>>;

function checkDraft(draft: IdentityDraft, token: string | null): { check: IdentityCheck | null; problems: IdentityProblems } {
  const problems: IdentityProblems = {};
  const code = normalizeCode(draft.code);
  if (!token && code.length !== 10) problems.code = 'Enter the 10-letter code from your printed sheet.';
  const dateOfBirth = birthDate(draft);
  if (!dateOfBirth) problems.birth = 'Enter your full date of birth.';
  if (!/^\d{4}$/.test(draft.ssnLast4)) problems.ssn = 'Enter the last 4 digits.';
  if (Object.keys(problems).length > 0 || !dateOfBirth) return { check: null, problems };
  return { check: token ? { token, dateOfBirth, ssnLast4: draft.ssnLast4 } : { code, dateOfBirth, ssnLast4: draft.ssnLast4 }, problems };
}

function IdentityFields({ draft, setDraft, problems, token }: { draft: IdentityDraft; setDraft: (draft: IdentityDraft) => void; problems: IdentityProblems; token: string | null }): ReactElement {
  const set = (field: keyof IdentityDraft) => (event: { target: { value: string } }): void => setDraft({ ...draft, [field]: event.target.value });
  return (
    <>
      {token ? (
        <p className="emp-message emp-message-info">Your invite link is ready. Enter two details to continue.</p>
      ) : (
        <Field
          label="Sign-up code"
          hint="The 10-letter code on the sheet from your manager."
          autoComplete="off"
          autoCapitalize="characters"
          spellCheck={false}
          value={draft.code}
          onChange={set('code')}
          error={problems.code}
          maxLength={16}
        />
      )}
      <fieldset className="emp-field" aria-describedby={problems.birth ? 'emp-birth-error' : undefined}>
        <legend className="emp-label">Date of birth</legend>
        <div className="emp-field-row">
          <div className="emp-field flex-[2]">
            <label htmlFor="emp-birth-month" className="emp-sublabel">Month</label>
            <select id="emp-birth-month" className="emp-input" autoComplete="bday-month" value={draft.month} onChange={set('month')} aria-invalid={problems.birth ? true : undefined}>
              <option value="">Month</option>
              {MONTHS.map((name, index) => <option key={name} value={String(index + 1)}>{name}</option>)}
            </select>
          </div>
          <div className="emp-field flex-1">
            <label htmlFor="emp-birth-day" className="emp-sublabel">Day</label>
            <input id="emp-birth-day" className="emp-input" inputMode="numeric" autoComplete="bday-day" maxLength={2} value={draft.day} onChange={set('day')} aria-invalid={problems.birth ? true : undefined} />
          </div>
          <div className="emp-field flex-[1.4]">
            <label htmlFor="emp-birth-year" className="emp-sublabel">Year</label>
            <input id="emp-birth-year" className="emp-input" inputMode="numeric" autoComplete="bday-year" maxLength={4} value={draft.year} onChange={set('year')} aria-invalid={problems.birth ? true : undefined} />
          </div>
        </div>
        {problems.birth && <p id="emp-birth-error" className="emp-field-error">{problems.birth}</p>}
      </fieldset>
      <Field
        label="Last 4 of your Social Security number"
        inputMode="numeric"
        autoComplete="off"
        maxLength={4}
        value={draft.ssnLast4}
        onChange={(event) => setDraft({ ...draft, ssnLast4: event.target.value.replace(/\D/g, '').slice(0, 4) })}
        error={problems.ssn}
        className="emp-field-short"
      />
    </>
  );
}

function TermsCheckbox({ terms, loadFailed, reload, checked, onChange, error }: { loadFailed: boolean; reload: () => void; terms: EmployeeTerms | null | undefined; checked: boolean; onChange: (checked: boolean) => void; error?: string | null }): ReactElement | null {
  if (loadFailed) return (
    <>
      <FormMessage tone="bad">Couldn’t load the Employee App Terms. Please try again.</FormMessage>
      <EmpButton type="button" onClick={reload}>Retry loading terms</EmpButton>
    </>
  );
  if (!terms) return <FormMessage tone={terms === null ? 'bad' : 'info'}>{terms === null ? 'Sign-up is unavailable right now. Reload to try again, or contact your manager.' : 'Loading the Employee App Terms…'}</FormMessage>;
  return (
    <div className="emp-field">
      <label className="emp-check">
        <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} aria-invalid={error ? true : undefined} aria-describedby={error ? 'emp-terms-error' : undefined} />
        <span>
          I agree to the{' '}
          <a className="emp-link-inline" href={terms.termsUrl} target="_blank" rel="noreferrer">{terms.title}</a>
          {' '}and{' '}
          <a className="emp-link-inline" href={terms.privacyUrl} target="_blank" rel="noreferrer">Privacy Notice</a>.
        </span>
      </label>
      {error && <p id="emp-terms-error" className="emp-field-error">{error}</p>}
    </div>
  );
}

// ---------- Messages ----------

function useCompany(): string {
  const brand = useBrand();
  return brand.isFallback ? 'your employer' : brand.name;
}

/**
 * One message for every failed check: wrong code, wrong date, expired, used,
 * revoked, unknown, or paused after too many tries (the API answers all of
 * them the same way, so this can't tell them apart either).
 */
function NoMatchMessage(): ReactElement {
  const brand = useBrand();
  return (
    <FormMessage tone="bad">
      <p className="font-bold">We couldn't match those details</p>
      <p>Check them and try again. After too many tries, sign-up pauses for 24 hours to keep your pay private.</p>
      <p>{askManager(brand, 'If it still doesn\'t work, ask your manager')}</p>
    </FormMessage>
  );
}

type Failure = 'no_match' | 'rate_limited' | 'offline' | 'server' | 'cancelled' | 'mfa_setup' | 'mfa_required' | 'signed_out' | 'terms_updated'
  | 'email_mismatch' | 'code_retired';

function failureOf(error: unknown): Failure {
  if (error instanceof StepUpCancelledError) return 'cancelled';
  if (!(error instanceof EmployeeApiError)) return 'server';
  switch (error.kind) {
    case 'terms_updated': return 'terms_updated';
    case 'email_mismatch': return 'email_mismatch';
    case 'code_retired': return 'code_retired';
    case 'invalid':
    case 'not_found':
    case 'conflict': return 'no_match';
    case 'unauthorized': return 'signed_out';
    case 'mfa_enrollment_required': return 'mfa_setup';
    case 'mfa_required': return 'mfa_required';
    case 'rate_limited': return 'rate_limited';
    case 'offline': return 'offline';
    default: return 'server';
  }
}

/** Two-step sign-in, for a staff or client login that is also an employee. Never "couldn't match". */
function TwoStepMessage({ kind }: { kind: 'mfa_setup' | 'mfa_required' }): ReactElement {
  const { openAccountSettings } = useEmployeeAuth();
  const signOut = useSignOut();
  if (kind === 'mfa_setup') {
    return (
      <FormMessage tone="bad">
        <p className="font-bold">Set up two-step sign-in first</p>
        <p>Your account needs two-step sign-in before it can add employee access. Set it up, then try again.</p>
        <EmpButton variant="secondary" className="emp-btn-small mt-2" onClick={openAccountSettings}>Set up two-step sign-in</EmpButton>
      </FormMessage>
    );
  }
  return (
    <FormMessage tone="bad">
      <p className="font-bold">Complete two-step sign-in</p>
      <p>This account uses two-step sign-in. Sign out, then sign in again with your second step.</p>
      <EmpButton variant="secondary" className="emp-btn-small mt-2" onClick={() => { void signOut(); }}>Sign out</EmpButton>
    </FormMessage>
  );
}

/** How long a 429 asked us to wait, from its Retry-After header. */
function retryAfterOf(error: unknown): number | null {
  return error instanceof EmployeeApiError ? error.retryAfterSeconds : null;
}

function FailureMessage({ failure, cancelledText, retryAfterSeconds }: { failure: Failure | null; cancelledText?: string; retryAfterSeconds?: number | null }): ReactElement | null {
  if (!failure) return null;
  if (failure === 'no_match') return <NoMatchMessage />;
  if (failure === 'email_mismatch') {
    return <FormMessage tone="bad">This invite is for a different email address. Sign in with the email your employer has on file, or ask them to update it.</FormMessage>;
  }
  if (failure === 'code_retired') {
    return <FormMessage tone="bad">This sign-up code can no longer be used. Ask your employer to send an invite to your email.</FormMessage>;
  }
  if (failure === 'mfa_setup' || failure === 'mfa_required') return <TwoStepMessage kind={failure} />;
  if (failure === 'cancelled') return <FormMessage tone="bad">{cancelledText ?? "Not done. Confirm it's you to continue."}</FormMessage>;
  if (failure === 'signed_out') return <FormMessage tone="bad">Your sign-in ended. Sign in again, then try again.</FormMessage>;
  if (failure === 'rate_limited') return <FormMessage tone="bad">{rateLimitedText(retryAfterSeconds)}</FormMessage>;
  if (failure === 'terms_updated') return <FormMessage tone="bad">The terms were updated. Please review them again.</FormMessage>;
  if (failure === 'offline') return <FormMessage tone="bad">You're offline. Connect to Wi-Fi or data, then try again.</FormMessage>;
  return <FormMessage tone="bad">Something went wrong on our end. Try again in a minute.</FormMessage>;
}

// ---------- Frame ----------

/** Back leaves sign-up, so it also drops the invite token kept for this tab. */
function AuthFrame({ back, children }: { back: string; children: ReactNode }): ReactElement {
  const brand = useBrand();
  return (
    <main className="emp-auth emp-auth-top">
      <div className="emp-auth-bar">
        <Link to={back} className="emp-back" onClick={forgetInviteToken}>
          <ChevronLeft aria-hidden="true" className="size-[26px]" />
          Back
        </Link>
        <span className="flex min-w-0 items-center gap-2">
          <BrandMark />
          <span className="min-w-0 break-words font-display text-[1.06rem] font-bold leading-tight">{brand.name}</span>
        </span>
      </div>
      {children}
    </main>
  );
}

function useAnonymousApi() {
  return useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken: async () => null }), []);
}

/** "Sign in", keeping the invite token: after sign-in the person lands on /claim. */
function SignInToClaim({ children = 'Sign in', className = 'emp-link-inline emp-link-standalone' }: { children?: ReactNode; className?: string }): ReactElement {
  return <Link to="/sign-in" state={{ from: '/claim' }} className={className}>{children}</Link>;
}

// ---------- New sign-up (/activate) ----------

const EMAIL = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

/**
 * Two steps on screen, one check on the API: step 1 collects the invite
 * details, step 2 the email, then both go in one POST /employee/activation.
 * A failed check comes back to step 1 with the one generic message.
 */
export function ActivateScreen(): ReactElement {
  const location = useLocation();
  // Read the token before the first render uses it.
  useState(() => takeInviteToken(location));
  const token = currentInviteToken();
  const api = useAnonymousApi();
  const company = useCompany();
  const [step, setStep] = useState<'details' | 'email' | 'sign_in'>('details');
  const [draft, setDraft] = useState<IdentityDraft>(EMPTY_DRAFT);
  const [problems, setProblems] = useState<IdentityProblems>({});
  const [check, setCheck] = useState<IdentityCheck | null>(null);
  const [email, setEmail] = useState('');
  const [useForNotices, setUseForNotices] = useState(false);
  const [agreed, setAgreed] = useState(false);
  const { terms, loadFailed, reload } = useEmployeeTerms();
  const [emailProblems, setEmailProblems] = useState<{ email?: string; terms?: string }>({});
  const [working, setWorking] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [retryAfterSeconds, setRetryAfterSeconds] = useState<number | null>(null);

  useDocumentTitle(step === 'email' ? 'Your email' : step === 'sign_in' ? 'Sign in instead' : 'Set up your account');

  const next = (event: FormEvent): void => {
    event.preventDefault();
    const result = checkDraft(draft, token);
    setProblems(result.problems);
    if (!result.check) return;
    setCheck(result.check);
    setFailure(null);
    setStep('email');
  };

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!check || !terms) return;
    const found: { email?: string; terms?: string } = {};
    if (!EMAIL.test(email.trim())) found.email = 'Enter an email address like name@example.com.';
    if (!agreed) found.terms = 'To create your account, agree to the Terms and Privacy Notice.';
    setEmailProblems(found);
    if (Object.keys(found).length > 0) return;
    setWorking(true);
    setFailure(null);
    try {
      const outcome = await api.activate(check, { email, useForNotices, termsVersion: terms.version }, window.location.origin);
      if (outcome.next === 'sign_in') {
        setStep('sign_in');
        setWorking(false);
        return;
      }
      // The Clerk invitation carries the link from here; the token isn't needed again.
      forgetInviteToken();
      window.location.assign(outcome.signUpUrl);
    } catch (error) {
      const result = failureOf(error);
      if (result === 'terms_updated') {
        setAgreed(false);
        reload();
      }
      setRetryAfterSeconds(retryAfterOf(error));
      setFailure(result);
      // Wrong details: back to the step that has them.
      if (result === 'no_match') setStep('details');
      setWorking(false);
    }
  };

  if (step === 'sign_in') {
    return (
      <AuthFrame back="/">
        <div className="emp-form emp-auth-form" role="status">
          <h1 className="emp-h1">We couldn't start a new account with that email</h1>
          <p className="emp-lead">If you already have an account, sign in. Then you can add your pay from {company} to it.</p>
          <SignInToClaim className="emp-btn emp-btn-primary emp-btn-block">Sign in</SignInToClaim>
          <EmpButton variant="secondary" block onClick={() => { setStep('email'); setFailure(null); }}>Use a different email</EmpButton>
          <CantSignIn />
        </div>
      </AuthFrame>
    );
  }

  if (step === 'email' && check) {
    return (
      <AuthFrame back="/">
        <form className="emp-form emp-auth-form" onSubmit={(event) => { void submit(event); }} noValidate>
          <div className="space-y-2">
            <p className="emp-step">Step 2 of 2</p>
            <h1 className="emp-h1">Your email</h1>
            <p className="emp-lead">You'll sign in with this email. Use your own, not one you share with family or work.</p>
          </div>
          <Field
            label="Your email"
            type="email"
            inputMode="email"
            autoComplete="email"
            autoCapitalize="none"
            spellCheck={false}
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            error={emailProblems.email}
            autoFocus
          />
          <div className="emp-field">
            <label className="emp-check">
              <input type="checkbox" checked={useForNotices} onChange={(event) => setUseForNotices(event.target.checked)} aria-describedby="emp-notices-hint" />
              <span>Send my pay stub notices to this email</span>
            </label>
            <p id="emp-notices-hint" className="emp-hint">
              If you leave this off, notices go to the email {company} has on file for you. If there isn't one, they come here.
            </p>
          </div>
          <TermsCheckbox terms={terms} loadFailed={loadFailed} reload={reload} checked={agreed} onChange={setAgreed} error={emailProblems.terms} />
          <FailureMessage failure={failure} retryAfterSeconds={retryAfterSeconds} />
          <EmpButton type="submit" block disabled={working || !terms} aria-busy={working}>{working ? 'Opening…' : 'Create account'}</EmpButton>
          <p className="emp-hint text-center">Next you'll choose a password, or use Google or an emailed code.</p>
          <EmpButton variant="quiet" block onClick={() => { setStep('details'); setFailure(null); }}>Back to step 1</EmpButton>
        </form>
      </AuthFrame>
    );
  }

  return (
    <AuthFrame back="/">
      <form className="emp-form emp-auth-form" onSubmit={next} noValidate>
        <div className="space-y-2">
          <p className="emp-step">Step 1 of 2</p>
          <h1 className="emp-h1">Set up your account</h1>
          <p className="emp-lead">First, tell us who you are. We'll check everything when you create your account.</p>
        </div>
        <IdentityFields draft={draft} setDraft={setDraft} problems={problems} token={token} />
        <FailureMessage failure={failure} retryAfterSeconds={retryAfterSeconds} />
        <EmpButton type="submit" block>Continue</EmpButton>
        <p className="text-center">
          Already have an account? <SignInToClaim />
        </p>
        <CantSignIn />
      </form>
    </AuthFrame>
  );
}

/** /sign-up: where Clerk's invitation lands (its redirect_url), with the ticket in the address. */
export function SignUpAccountScreen(): ReactElement {
  const { SignUpForm } = useEmployeeAuth();
  const { search } = useLocation();
  const hasTicket = Boolean(new URLSearchParams(search).get('__clerk_ticket')?.trim());
  useDocumentTitle('Create your account');
  return (
    <AuthFrame back="/">
      {hasTicket ? <SignUpForm redirectTo="/sign-up/done" /> : (
        <div className="space-y-4">
          <h1 className="emp-h1">Set up your account</h1>
          <p className="emp-lead">To set up your account, open the invite link from your email.</p>
          <Link to="/sign-in" className="emp-link">Sign in</Link>
        </div>
      )}
    </AuthFrame>
  );
}

/** Signed in after Clerk sign-up: /auth/me binds the invited link, then "Go paperless?" asks once before Home. */
export function FinishSignUpScreen(): ReactElement {
  const { getToken } = useEmployeeAuth();
  const brand = useBrand();
  const signOut = useSignOut();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const navigate = useNavigate();
  const [attempt, setAttempt] = useState(0);
  const [failed, setFailed] = useState<Failure | null>(null);
  useDocumentTitle(failed ? "Couldn't finish setting up" : 'Setting up');

  useEffect(() => {
    let current = true;
    setFailed(null);
    api.bindAccount().then(() => {
      if (current) navigate(PAPERLESS_PATH, { replace: true });
    }, (error: unknown) => {
      if (!current) return;
      const failure = failureOf(error);
      setFailed(failure === 'offline' || failure === 'rate_limited' || failure === 'mfa_setup' || failure === 'mfa_required' ? failure : 'server');
    });
    return () => { current = false; };
  }, [api, attempt, navigate]);

  return (
    <main className="emp-auth">
      <div className="emp-auth-grow" aria-busy={!failed}>
        <BrandMark size="lg" />
        <h1 className="emp-h1">{failed ? "We couldn't finish setting up" : 'Setting up your account…'}</h1>
        {failed === 'server' ? (
          <FormMessage tone="bad">
            <p>Your account was made, but we couldn't connect it to your pay yet. Try again in a minute.</p>
          </FormMessage>
        ) : <FailureMessage failure={failed} />}
        {failed && <p className="text-neutral-700">{askManager(brand, 'Still not working? Sign out and ask your manager')} They can send you a new invite.</p>}
      </div>
      {failed && (
        <div className="space-y-2">
          <EmpButton block onClick={() => setAttempt((n) => n + 1)}>Try again</EmpButton>
          <EmpButton block variant="quiet" onClick={() => { void signOut(); }}>Sign out</EmpButton>
        </div>
      )}
    </main>
  );
}

// ---------- Existing login (/claim) and rehired login (/reactivate) ----------

const LINK_CHECK = {
  claim: {
    title: 'Add your employee access',
    lead: (company: string) => `You're signed in. To see your pay from ${company} with this account, check it's you.`,
    button: 'Add access',
    working: 'Checking…',
    cancelled: "Not added. To add your access, confirm it's you.",
  },
  reactivate: {
    title: 'Welcome back',
    lead: (company: string) => `You're signed in with your old account. To see your pay from ${company} again, check it's you.`,
    button: 'Turn my account back on',
    working: 'Checking…',
    cancelled: "Not done. To turn your account back on, confirm it's you.",
  },
} as const;

/** Signed in: the invite check plus step-up adds this job to the login (claim) or opens a rehired login again (reactivate). */
export function LinkCheckScreen({ mode }: { mode: 'claim' | 'reactivate' }): ReactElement {
  const location = useLocation();
  useState(() => takeInviteToken(location));
  const token = currentInviteToken();
  const { email, getToken, stepUp } = useEmployeeAuth();
  const signOut = useSignOut();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const navigate = useNavigate();
  const company = useCompany();
  const copy = LINK_CHECK[mode];
  const [draft, setDraft] = useState<IdentityDraft>(EMPTY_DRAFT);
  const [problems, setProblems] = useState<IdentityProblems & { terms?: string }>({});
  const [agreed, setAgreed] = useState(false);
  const { terms, loadFailed, reload } = useEmployeeTerms();
  const [working, setWorking] = useState(false);
  const [switchingAccount, setSwitchingAccount] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [retryAfterSeconds, setRetryAfterSeconds] = useState<number | null>(null);
  useDocumentTitle(copy.title);

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (switchingAccount) return;
    const result = checkDraft(draft, token);
    const found: IdentityProblems & { terms?: string } = { ...result.problems };
    if (!agreed) found.terms = 'To continue, agree to the Terms and Privacy Notice.';
    setProblems(found);
    if (!terms || !result.check || found.terms) return;
    const checked = result.check;
    const termsVersion = terms.version;
    setWorking(true);
    setFailure(null);
    try {
      await stepUp(() => (mode === 'claim' ? api.claimLink(checked, termsVersion) : api.reactivate(checked, termsVersion)));
      forgetInviteToken();
      // Asked once on the way in; the step goes straight to Home when there's already an answer.
      navigate(PAPERLESS_PATH, { replace: true });
    } catch (error) {
      const result = failureOf(error);
      if (result === 'terms_updated') {
        setAgreed(false);
        reload();
      }
      setRetryAfterSeconds(retryAfterOf(error));
      setFailure(result);
    } finally {
      setWorking(false);
    }
  };

  return (
    <AuthFrame back="/">
      <form className="emp-form emp-auth-form" onSubmit={(event) => { void submit(event); }} noValidate>
        <div className="space-y-2">
          <h1 className="emp-h1">{copy.title}</h1>
          <p className="emp-lead">{copy.lead(company)}</p>
        </div>
        {mode === 'claim' && email && (
          <div className="emp-notice-inline">
            <p>Signed in as <strong className="break-all">{email}</strong></p>
            <p className="flex flex-wrap items-center gap-x-2">
              Not you?
              <EmpButton variant="quiet" className="emp-btn-small" disabled={working || switchingAccount} onClick={() => {
                setSwitchingAccount(true);
                void signOut('/claim').then((signedOut) => { if (!signedOut) setSwitchingAccount(false); });
              }}>Sign out and use your invite again</EmpButton>
            </p>
          </div>
        )}
        <IdentityFields draft={draft} setDraft={setDraft} problems={problems} token={token} />
        <TermsCheckbox terms={terms} loadFailed={loadFailed} reload={reload} checked={agreed} onChange={setAgreed} error={problems.terms} />
        <FailureMessage failure={failure} cancelledText={copy.cancelled} retryAfterSeconds={retryAfterSeconds} />
        <p className="emp-hint">To keep your pay private, we'll ask you to confirm it's you with your password or a code.</p>
        <EmpButton type="submit" block disabled={working || switchingAccount || !terms} aria-busy={working}>{working ? copy.working : copy.button}</EmpButton>
        {!token && <p className="emp-hint text-center">Got an invite email? Open its link on this device instead of typing a code.</p>}
      </form>
    </AuthFrame>
  );
}

/**
 * Signed out on /claim or /reactivate: keep the invite token for this tab,
 * then sign in and come back here. Google sign-in leaves the page and returns
 * to `to`, which finds the token in sessionStorage.
 */
export function SignInFirst({ to }: { to: '/claim' | '/reactivate' }): ReactElement {
  const location = useLocation();
  takeInviteToken(location);
  return <Navigate to="/sign-in" replace state={{ from: to }} />;
}

/** Signed in on /activate: this person already has a login, so the invite adds access to it. */
export function SignedInInvite(): ReactElement {
  const location = useLocation();
  takeInviteToken(location);
  return <Navigate to="/claim" replace />;
}
