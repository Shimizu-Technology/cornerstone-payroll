// "Go paperless?": one short question after sign-up or adding access, and
// small Home cards that keep asking until the employee answers. Answering never
// blocks the app and never turns paper off: paper continues for everyone until
// electronic-only delivery is switched on (ElectronicOnlyReadiness). Yes runs
// the same pay statement consent as My info (step-up, counsel-draft disclosure
// verbatim behind "Read the full disclosure"); Keep paper records the answer
// without a consent. W-2GU consent stays on Tax forms, with its PDF check.
import { useRef, useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router';
import { Mail, ShieldCheck, X } from 'lucide-react';
import { DisclosureBody } from './consent';
import { consentErrorMessage, KIND_COPY } from './consentCopy';
import { EmployeeApiError } from './api';
import type { DeliveryConsentItem, DeliveryConsentsState, DeliveryConsentKind } from './contracts';
import { useEmployeeAuth, useReadySession } from './contexts';
import { focusHeadingOnNextScreen } from './focus';
import {
  deliveryCardHidden, hideDeliveryCard, inW2GuSeason, PAPERLESS_PATH, upcomingW2GuYear, type DeliveryCardKind,
} from './paperlessState';
import { Card, EmpButton, EmpButtonLink, FormMessage, LoadProblem, Page, SkeletonRows } from './ui';
import { isSessionError, useEmployeeData } from './useEmployeeData';

type HomeState = { deliveryNotice?: string } | null;

function useDeliveryConsents() {
  return useEmployeeData<DeliveryConsentsState>(
    'delivery-consents',
    (api, linkId, signal) => api.deliveryConsents(linkId, signal),
  );
}

function itemFor(state: DeliveryConsentsState, kind: DeliveryConsentKind): DeliveryConsentItem | undefined {
  return state.consents.find((entry) => entry.kind === kind);
}

/** Who can be asked: the switch is on, and this is the employee's own current job. */
function useCanAsk(): boolean {
  const { state, isFormer, isViewOnly } = useReadySession();
  return state.info.features.deliveryConsent && !isFormer && !isViewOnly;
}

// ---------- The step ----------

export function PaperlessStep(): ReactElement {
  if (!useCanAsk()) return <Navigate to="/" replace />;
  return <PaperlessQuestion />;
}

function PaperlessQuestion(): ReactElement {
  const { api, state: session, reportError } = useReadySession();
  const { stepUp, openAccountSettings } = useEmployeeAuth();
  const { state, reload, update } = useDeliveryConsents();
  const navigate = useNavigate();
  const location = useLocation();
  const fromHome = (location.state as { from?: unknown } | null)?.from === 'home';

  const [choosingYes, setChoosingYes] = useState(false);
  const [disclosureOpen, setDisclosureOpen] = useState(false);
  const [agreed, setAgreed] = useState(false);
  const [saving, setSaving] = useState<'yes' | 'paper' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [needsTwoStep, setNeedsTwoStep] = useState(false);
  // Set before the answer reaches the shared data, so the "already answered"
  // redirect below never races the confirmation sent to Home.
  const answered = useRef(false);
  const yesHeading = useRef<HTMLHeadingElement>(null);
  const yesButton = useRef<HTMLButtonElement>(null);

  const finish = (notice?: string): void => {
    answered.current = true;
    focusHeadingOnNextScreen();
    navigate('/', { replace: true, state: notice ? { deliveryNotice: notice } : null });
  };

  const decideLater = (): void => {
    // Asked from the Home card: don't ask again there for the rest of this visit.
    if (fromHome) hideDeliveryCard(session.link.id, 'pay_statements');
    finish();
  };

  if (state.status === 'loading') {
    return <Page title="Go paperless?"><Card><SkeletonRows rows={3} label="Loading" /></Card></Page>;
  }
  if (state.status === 'error') {
    return (
      <Page title="Go paperless?">
        <Card>
          <div className="space-y-4">
            <LoadProblem kind={state.kind} onRetry={reload} what="this question" />
            <EmpButton variant="quiet" block className="emp-narrow-button" onClick={() => finish()}>Continue to the app</EmpButton>
          </div>
        </Card>
      </Page>
    );
  }

  const item = itemFor(state.data, 'pay_statements');
  const disclosure = item?.disclosure ?? null;
  if (!answered.current && (!item || !disclosure || item.answer !== 'not_answered')) return <Navigate to="/" replace />;
  if (!item || !disclosure) return <Navigate to="/" replace />;

  const failed = (failure: unknown, fallback: string): void => {
    if (failure instanceof EmployeeApiError && failure.kind === 'mfa_enrollment_required') {
      setNeedsTwoStep(true);
      setError('Not saved. Set up two-step sign-in first, then try again.');
    } else if (isSessionError(failure)) {
      reportError(failure);
    } else {
      setError(consentErrorMessage(failure, fallback));
      if (failure instanceof EmployeeApiError && failure.kind === 'disclosure_outdated') reload();
    }
  };

  const goPaperless = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!agreed) {
      setError('To go paperless, check the box to agree.');
      return;
    }
    setSaving('yes');
    setError(null);
    setNeedsTwoStep(false);
    try {
      const next = await stepUp(() => api.giveDeliveryConsent(session.link.id, {
        kind: 'pay_statements',
        disclosureVersion: disclosure.version,
        disclosureDigest: disclosure.digest,
      }));
      answered.current = true;
      update(next);
      finish("You're set to go paperless. Paper pay stubs still come for now.");
    } catch (failure) {
      failed(failure, "Couldn't save your answer. Try again in a minute.");
    } finally {
      setSaving(null);
    }
  };

  const keepPaper = async (): Promise<void> => {
    setSaving('paper');
    setError(null);
    setNeedsTwoStep(false);
    try {
      const next = await api.keepPaperDelivery(session.link.id, 'pay_statements');
      answered.current = true;
      update(next);
      finish("Saved. You'll keep getting paper pay stubs.");
    } catch (failure) {
      failed(failure, "Couldn't save your answer. Try again in a minute.");
    } finally {
      setSaving(null);
    }
  };

  const disclosureId = 'emp-paperless-disclosure';
  const busy = saving !== null;

  return (
    <Page title="Go paperless?">
      <Card className="emp-paperless">
        <div className="space-y-4">
          <p className="emp-lead">Get your pay stubs in this app instead of on paper.</p>
          <ul className="emp-paperless-points">
            <li>Paper pay stubs keep coming for now.</li>
            <li>We save your answer for when paperless delivery starts.</li>
            <li>You can change it any time in My info.</li>
          </ul>

          {error && (
            <FormMessage tone="bad">
              <p>{error}</p>
              {needsTwoStep && (
                <EmpButton variant="secondary" className="emp-btn-small mt-2" onClick={openAccountSettings}>
                  Set up two-step sign-in
                </EmpButton>
              )}
            </FormMessage>
          )}

          {choosingYes ? (
            <form
              className="emp-form"
              aria-labelledby="emp-paperless-yes"
              onSubmit={(event) => { void goPaperless(event); }}
              noValidate
            >
              <h2 id="emp-paperless-yes" ref={yesHeading} tabIndex={-1} className="emp-h2">Go paperless</h2>
              <div>
                <button
                  type="button"
                  className="emp-disclosure-toggle"
                  aria-expanded={disclosureOpen}
                  aria-controls={disclosureId}
                  onClick={() => setDisclosureOpen((open) => !open)}
                >
                  {disclosureOpen ? 'Hide the full disclosure' : 'Read the full disclosure'}
                </button>
                <div id={disclosureId} className="emp-disclosure-panel space-y-2" hidden={!disclosureOpen}>
                  <p className="emp-label-quiet">{disclosure.title}</p>
                  <DisclosureBody text={disclosure.text} />
                </div>
              </div>
              <label className="emp-checkbox-row" htmlFor="emp-paperless-agree">
                <input
                  id="emp-paperless-agree"
                  type="checkbox"
                  className="emp-checkbox"
                  checked={agreed}
                  onChange={(event) => setAgreed(event.target.checked)}
                  disabled={busy}
                />
                <span>{KIND_COPY.pay_statements.agreeLabel}</span>
              </label>
              <p className="emp-hint emp-inline-icon">
                <ShieldCheck aria-hidden="true" className="size-5 shrink-0" />
                To keep your account safe, we'll ask you to confirm it's you.
              </p>
              <div className="emp-paperless-actions">
                <EmpButton type="submit" block disabled={busy || !agreed} aria-busy={saving === 'yes'}>
                  {saving === 'yes' ? 'Saving…' : 'Go paperless'}
                </EmpButton>
                <EmpButton
                  variant="quiet"
                  block
                  disabled={busy}
                  onClick={() => {
                    setChoosingYes(false);
                    setError(null);
                    window.requestAnimationFrame(() => yesButton.current?.focus());
                  }}
                >
                  Back
                </EmpButton>
              </div>
            </form>
          ) : (
            <div className="emp-paperless-actions">
              <EmpButton
                ref={yesButton}
                block
                disabled={busy}
                onClick={() => {
                  setChoosingYes(true);
                  setError(null);
                  window.requestAnimationFrame(() => yesHeading.current?.focus());
                }}
              >
                Yes, go paperless
              </EmpButton>
              <EmpButton variant="secondary" block disabled={busy} aria-busy={saving === 'paper'} onClick={() => { void keepPaper(); }}>
                {saving === 'paper' ? 'Saving…' : 'Keep paper'}
              </EmpButton>
              <EmpButton variant="quiet" block disabled={busy} onClick={decideLater}>
                Decide later
              </EmpButton>
            </div>
          )}
        </div>
      </Card>
    </Page>
  );
}

// ---------- Home ----------

/** The confirmation from the step, and the cards that ask until there's an answer. */
export function DeliveryHomeCards({ now }: { now?: Date } = {}): ReactElement | null {
  const location = useLocation();
  const canAsk = useCanAsk();
  const notice = (location.state as HomeState)?.deliveryNotice;
  return (
    <>
      {typeof notice === 'string' && <FormMessage tone="good">{notice}</FormMessage>}
      {canAsk && <DeliveryAskCards now={now} />}
    </>
  );
}

function DeliveryAskCards({ now }: { now?: Date }): ReactElement | null {
  const { state: session } = useReadySession();
  const linkId = session.link.id;
  const { state } = useDeliveryConsents();
  const [hidden, setHidden] = useState(() => ({
    pay_statements: deliveryCardHidden(linkId, 'pay_statements'),
    w2gu: deliveryCardHidden(linkId, 'w2gu'),
  }));
  // Quiet on Home: a load problem here never gets in the way of pay.
  if (state.status !== 'ready') return null;

  const unanswered = (kind: DeliveryConsentKind): boolean => {
    const item = itemFor(state.data, kind);
    return Boolean(item?.disclosure && item.answer === 'not_answered' && !hidden[kind]);
  };
  const hide = (kind: DeliveryCardKind): void => {
    hideDeliveryCard(linkId, kind);
    setHidden((current) => ({ ...current, [kind]: true }));
  };
  const at = now ?? new Date();
  const showPay = unanswered('pay_statements');
  const showW2 = unanswered('w2gu') && inW2GuSeason(at);
  if (!showPay && !showW2) return null;

  return (
    <div className="emp-ask-cards">
      {showPay && (
        <AskCard
          title="Choose how you get pay stubs"
          onHide={() => hide('pay_statements')}
          to={PAPERLESS_PATH}
          state={{ from: 'home' }}
          linkLabel="Choose"
        >
          Go paperless or keep paper. Paper pay stubs keep coming for now either way.
        </AskCard>
      )}
      {showW2 && (
        <AskCard
          title="Get your W-2GU online?"
          onHide={() => hide('w2gu')}
          to="/taxes"
          linkLabel="Choose for W-2GU"
        >
          Your {upcomingW2GuYear(at)} Form W-2GU comes by January 31. You can choose to get it in this app. Paper copies keep coming for now.
        </AskCard>
      )}
    </div>
  );
}

function AskCard({ title, onHide, to, state, linkLabel, children }: {
  title: string;
  onHide: () => void;
  to: string;
  state?: unknown;
  linkLabel: string;
  children: ReactNode;
}): ReactElement {
  return (
    <Card
      title={title}
      className="emp-ask-card"
      action={(
        <EmpButton variant="quiet" className="emp-icon-button" aria-label={`Not now: ${title}`} onClick={onHide}>
          <X aria-hidden="true" className="size-5" />
        </EmpButton>
      )}
    >
      <div className="emp-ask-card-body">
        <Mail aria-hidden="true" className="size-6 shrink-0 text-[var(--action)]" />
        <div className="min-w-0 flex-1 space-y-3">
          <p className="text-neutral-700">{children}</p>
          <EmpButtonLink to={to} state={state} variant="secondary" className="emp-btn-small" onClick={focusHeadingOnNextScreen}>
            {linkLabel}
          </EmpButtonLink>
        </div>
      </div>
    </Card>
  );
}
