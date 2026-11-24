// Sign-up and "add your employee access" (M4-2).
// - New person: the invite link (or a printed code) + date of birth + last 4
//   of the SSN, then their email, then Clerk's own sign-up opens from the
//   invitation URL the API returns. Back in the app, /auth/me binds the link.
// - Someone who already has a login: sign in first, then the same check plus
//   step-up, and the link is added to that login.
// Every failed check shows one message. None says whether a person, an email
// or an invite exists.
import { useEffect, useMemo, useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { ChevronLeft, LockKeyhole } from 'lucide-react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router';
import { createEmployeeApi, EmployeeApiError, StepUpCancelledError } from './api';
import { askManager } from './brand';
import { API_BASE_URL, TERMS } from './config';
import type { IdentityCheck } from './contracts';
import { useBrand, useEmployeeAuth } from './contexts';
import { CantSignIn } from './help';
import { useDocumentTitle } from './hooks';
import { birthDate, currentInviteToken, forgetInviteToken, normalizeCode, takeInviteToken } from './signupState';
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
        <p className="emp-message emp-message-info">Your invite link is ready. Confirm two details to continue.</p>
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

function TermsCheckbox({ checked, onChange, error }: { checked: boolean; onChange: (checked: boolean) => void; error?: string | null }): ReactElement | null {
  if (!TERMS) return null;
  return (
    <div className="emp-field">
      <label className="emp-check">
        <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} aria-invalid={error ? true : undefined} aria-describedby={error ? 'emp-terms-error' : undefined} />
        <span>
          I agree to the{' '}
          <a className="emp-link-inline" href={TERMS.termsUrl} target="_blank" rel="noreferrer">Employee App Terms</a>
          {' '}and{' '}
          <a className="emp-link-inline" href={TERMS.privacyUrl} target="_blank" rel="noreferrer">Privacy Notice</a>.
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

/** One message for every failed check: wrong code, wrong date, expired, used, revoked or unknown. */
function NoMatchMessage(): ReactElement {
  const brand = useBrand();
  return (
    <FormMessage tone="bad">
      <p className="font-bold">We couldn't match those details</p>
      <p>Check them and try again. {askManager(brand, 'If it still doesn\'t work, ask your manager')}</p>
    </FormMessage>
  );
}

type Failure = 'no_match' | 'rate_limited' | 'offline' | 'server' | 'cancelled';

function failureOf(error: unknown): Failure | 'locked' {
  if (error instanceof StepUpCancelledError) return 'cancelled';
  if (!(error instanceof EmployeeApiError)) return 'server';
  switch (error.kind) {
    case 'invalid':
    case 'not_found':
    case 'conflict':
    case 'unauthorized': return 'no_match';
    case 'locked': return 'locked';
    case 'rate_limited': return 'rate_limited';
    case 'offline': return 'offline';
    default: return 'server';
  }
}

function FailureMessage({ failure, cancelledText }: { failure: Failure | null; cancelledText?: string }): ReactElement | null {
  if (!failure) return null;
  if (failure === 'no_match') return <NoMatchMessage />;
  if (failure === 'cancelled') return <FormMessage tone="bad">{cancelledText ?? "Not done. Confirm it's you to continue."}</FormMessage>;
  if (failure === 'rate_limited') return <FormMessage tone="bad">Too many tries. Wait a minute, then try again.</FormMessage>;
  if (failure === 'offline') return <FormMessage tone="bad">You're offline. Connect to Wi-Fi or data, then try again.</FormMessage>;
  return <FormMessage tone="bad">Something went wrong on our end. Try again in a minute.</FormMessage>;
}

/** After 5 failed checks the API pauses sign-up for this invite for 24 hours. */
export function LockedScreen(): ReactElement {
  const brand = useBrand();
  useDocumentTitle('Sign-up paused');
  return (
    <AuthFrame back="/">
      <div className="emp-auth-grow" role="alert">
        <span aria-hidden="true" className="grid size-[72px] place-items-center rounded-full bg-neutral-200 text-neutral-800">
          <LockKeyhole className="size-[34px]" />
        </span>
        <h1 className="emp-h1">Sign-up is paused</h1>
        <p className="emp-lead">After too many tries, we pause sign-up for 24 hours to keep your pay private.</p>
        <p className="text-neutral-700">{askManager(brand, 'Need it sooner? Ask your manager')} They can ask Cornerstone to unlock it.</p>
      </div>
    </AuthFrame>
  );
}

// ---------- Frame ----------

function AuthFrame({ back, children }: { back: string; children: ReactNode }): ReactElement {
  const brand = useBrand();
  return (
    <main className="emp-auth emp-auth-top">
      <div className="emp-auth-bar">
        <Link to={back} className="emp-back">
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

// ---------- New sign-up ----------

export function SignUpScreen(): ReactElement {
  const location = useLocation();
  // Read the token before the first render uses it.
  useState(() => takeInviteToken(location));
  const token = currentInviteToken();
  const api = useAnonymousApi();
  const company = useCompany();
  const [step, setStep] = useState<'check' | 'account' | 'locked'>('check');
  const [draft, setDraft] = useState<IdentityDraft>(EMPTY_DRAFT);
  const [problems, setProblems] = useState<IdentityProblems>({});
  const [check, setCheck] = useState<IdentityCheck | null>(null);
  const [recordEmailHint, setRecordEmailHint] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);

  useDocumentTitle(step === 'account' ? 'Your email' : 'Set up your account');

  const verify = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const result = checkDraft(draft, token);
    setProblems(result.problems);
    if (!result.check) return;
    setWorking(true);
    setFailure(null);
    try {
      const verified = await api.verifyActivation(result.check);
      setCheck(result.check);
      setRecordEmailHint(verified.recordEmailHint);
      setStep('account');
    } catch (error) {
      const next = failureOf(error);
      if (next === 'locked') setStep('locked');
      else setFailure(next);
    } finally {
      setWorking(false);
    }
  };

  if (step === 'locked') return <LockedScreen />;
  if (step === 'account' && check) return <AccountStep check={check} recordEmailHint={recordEmailHint} onLocked={() => setStep('locked')} onBack={() => setStep('check')} />;

  return (
    <AuthFrame back="/">
      <form className="emp-form emp-auth-form" onSubmit={(event) => { void verify(event); }} noValidate>
        <div className="space-y-2">
          <p className="emp-step">Step 1 of 2</p>
          <h1 className="emp-h1">Set up your account</h1>
          <p className="emp-lead">First, let's check it's you. We use these to match you to your pay at {company}.</p>
        </div>
        <IdentityFields draft={draft} setDraft={setDraft} problems={problems} token={token} />
        <FailureMessage failure={failure} />
        <EmpButton type="submit" block disabled={working} aria-busy={working}>{working ? 'Checking…' : 'Continue'}</EmpButton>
        <p className="text-center">
          Already have an account?{' '}
          <Link to="/sign-in" state={{ from: '/add-access' }} className="emp-link-inline">Sign in</Link>
        </p>
        <CantSignIn />
      </form>
    </AuthFrame>
  );
}

function AccountStep({ check, recordEmailHint, onLocked, onBack }: { check: IdentityCheck; recordEmailHint: string | null; onLocked: () => void; onBack: () => void }): ReactElement {
  const api = useAnonymousApi();
  const company = useCompany();
  const [email, setEmail] = useState('');
  const [notice, setNotice] = useState<'sign_in' | 'record'>('sign_in');
  const [agreed, setAgreed] = useState(false);
  const [problems, setProblems] = useState<{ email?: string; terms?: string }>({});
  const [working, setWorking] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const next: { email?: string; terms?: string } = {};
    if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email.trim())) next.email = 'Enter an email address like name@example.com.';
    if (TERMS && !agreed) next.terms = 'To create your account, agree to the Terms and Privacy Notice.';
    setProblems(next);
    if (Object.keys(next).length > 0) return;
    setWorking(true);
    setFailure(null);
    try {
      const url = await api.startActivation(check, { email, noticeEmail: recordEmailHint ? notice : 'sign_in', termsVersion: TERMS?.version ?? null }, window.location.origin);
      forgetInviteToken();
      window.location.assign(url);
    } catch (error) {
      const result = failureOf(error);
      if (result === 'locked') onLocked();
      else setFailure(result);
      setWorking(false);
    }
  };

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
          error={problems.email}
          autoFocus
        />
        {recordEmailHint && (
          <fieldset className="emp-field">
            <legend className="emp-label">Where should pay stub notices go?</legend>
            <p className="emp-hint">{company} has a different email on file for you.</p>
            <label className="emp-radio">
              <input type="radio" name="notice" checked={notice === 'sign_in'} onChange={() => setNotice('sign_in')} />
              <span>The email I just entered</span>
            </label>
            <label className="emp-radio">
              <input type="radio" name="notice" checked={notice === 'record'} onChange={() => setNotice('record')} />
              <span>The email on file: <span className="break-all font-semibold">{recordEmailHint}</span></span>
            </label>
          </fieldset>
        )}
        <TermsCheckbox checked={agreed} onChange={setAgreed} error={problems.terms} />
        {failure === 'no_match' ? (
          <FormMessage tone="bad">
            <p className="font-bold">We couldn't create an account with that email</p>
            <p>Try another email. If you already have an account, <Link to="/sign-in" state={{ from: '/add-access' }} className="emp-link-inline">sign in</Link> instead.</p>
          </FormMessage>
        ) : <FailureMessage failure={failure} />}
        <EmpButton type="submit" block disabled={working} aria-busy={working}>{working ? 'Opening…' : 'Create account'}</EmpButton>
        <p className="emp-hint text-center">Next you'll choose a password, or use Google or an emailed code.</p>
        <EmpButton variant="quiet" block onClick={onBack}>Back to step 1</EmpButton>
      </form>
    </AuthFrame>
  );
}

/** Where Clerk's invitation lands: Clerk's own sign-up, which reads the ticket from the address. */
export function SignUpAccountScreen(): ReactElement {
  const { SignUpForm } = useEmployeeAuth();
  useDocumentTitle('Create your account');
  return (
    <AuthFrame back="/">
      <SignUpForm redirectTo="/sign-up/done" />
    </AuthFrame>
  );
}

/** Signed in after Clerk sign-up: /auth/me binds the invited link, then Home opens. */
export function FinishSignUpScreen(): ReactElement {
  const { getToken } = useEmployeeAuth();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const navigate = useNavigate();
  const [attempt, setAttempt] = useState(0);
  const [failed, setFailed] = useState<Failure | null>(null);
  useDocumentTitle('Setting up');

  useEffect(() => {
    let current = true;
    setFailed(null);
    api.bindAccount().then(() => {
      if (current) navigate('/', { replace: true });
    }, (error: unknown) => {
      if (current) setFailed(failureOf(error) === 'offline' ? 'offline' : 'server');
    });
    return () => { current = false; };
  }, [api, attempt, navigate]);

  return (
    <main className="emp-auth">
      <div className="emp-auth-grow" aria-busy={!failed}>
        <BrandMark size="lg" />
        <h1 className="emp-h1">{failed ? "We couldn't finish setting up" : 'Setting up your account…'}</h1>
        {failed && <FailureMessage failure={failed} />}
      </div>
      {failed && <EmpButton block onClick={() => setAttempt((n) => n + 1)}>Try again</EmpButton>}
    </main>
  );
}

// ---------- Existing login ----------

export function AddAccessScreen(): ReactElement {
  const location = useLocation();
  useState(() => takeInviteToken(location));
  const token = currentInviteToken();
  const { getToken, stepUp } = useEmployeeAuth();
  const api = useMemo(() => createEmployeeApi({ baseUrl: API_BASE_URL, getToken }), [getToken]);
  const navigate = useNavigate();
  const company = useCompany();
  const [draft, setDraft] = useState<IdentityDraft>(EMPTY_DRAFT);
  const [problems, setProblems] = useState<IdentityProblems & { terms?: string }>({});
  const [agreed, setAgreed] = useState(false);
  const [working, setWorking] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [locked, setLocked] = useState(false);
  useDocumentTitle('Add your employee access');

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const result = checkDraft(draft, token);
    const next: IdentityProblems & { terms?: string } = { ...result.problems };
    if (TERMS && !agreed) next.terms = 'To add access, agree to the Terms and Privacy Notice.';
    setProblems(next);
    if (!result.check || next.terms) return;
    const checked = result.check;
    setWorking(true);
    setFailure(null);
    try {
      await stepUp(() => api.claimLink(checked, TERMS?.version ?? null));
      forgetInviteToken();
      navigate('/', { replace: true });
    } catch (error) {
      const outcome = failureOf(error);
      if (outcome === 'locked') setLocked(true);
      else setFailure(outcome);
    } finally {
      setWorking(false);
    }
  };

  if (locked) return <LockedScreen />;
  return (
    <AuthFrame back="/">
      <form className="emp-form emp-auth-form" onSubmit={(event) => { void submit(event); }} noValidate>
        <div className="space-y-2">
          <h1 className="emp-h1">Add your employee access</h1>
          <p className="emp-lead">You're signed in. To see your pay from {company} with this account, check it's you.</p>
        </div>
        <IdentityFields draft={draft} setDraft={setDraft} problems={problems} token={token} />
        <TermsCheckbox checked={agreed} onChange={setAgreed} error={problems.terms} />
        <FailureMessage failure={failure} cancelledText="Not added. To add your access, confirm it's you." />
        <p className="emp-hint">To keep your pay private, we'll ask you to confirm it's you with your password or a code.</p>
        <EmpButton type="submit" block disabled={working} aria-busy={working}>{working ? 'Checking…' : 'Add access'}</EmpButton>
        {!token && <p className="emp-hint text-center">Got an invite email? Open its link on this device instead of typing a code.</p>}
      </form>
    </AuthFrame>
  );
}

/** A signed-in person who opens an invite link adds the access to this login. */
export function SignedInInvite(): ReactElement {
  const location = useLocation();
  takeInviteToken(location);
  return <Navigate to="/add-access" replace />;
}
