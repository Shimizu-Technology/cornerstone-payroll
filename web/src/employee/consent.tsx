// Electronic-delivery consent cards for pay statements and Form W-2GU (M4-6).
// Hidden unless the company's employee_portal.features.delivery_consent switch is on.
// Regular employees see disclosure text plainly; staff and dev see a small "Draft wording" marker
// while a disclosure is in draft status. Paper delivery continues during the pilot (D5).
import { useEffect, useState, type FormEvent, type ReactElement } from 'react';
import { CheckCircle2, FileText, Mail, Printer, ShieldCheck } from 'lucide-react';
import { EmployeeApiError, StepUpCancelledError } from './api';
import {
  accessDay,
  type DeliveryConsentItem,
  type DeliveryConsentKind,
  type DeliveryConsentsState,
  type W2GuAccessProofChallenge,
} from './contracts';
import { useEmployeeAuth, useReadySession } from './contexts';
import { longDate } from './format';
import { Card, Chip, EmpButton, Field, FormMessage, LoadProblem, SkeletonRows } from './ui';
import { isSessionError, useEmployeeData } from './useEmployeeData';

const KIND_COPY: Record<DeliveryConsentKind, { heading: string; shortLabel: string; agreeLabel: string }> = {
  pay_statements: {
    heading: 'Electronic pay statements',
    shortLabel: 'pay statements',
    agreeLabel: 'I have read this disclosure and agree to electronic delivery of my pay statements.',
  },
  w2gu: {
    heading: 'Electronic Form W-2GU',
    shortLabel: 'Form W-2GU',
    agreeLabel: 'I have read this disclosure and agree to electronic delivery of my Form W-2GU.',
  },
};

function openBase64Pdf(base64: string, filename: string): boolean {
  try {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    const blob = new Blob([bytes], { type: 'application/pdf' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    link.rel = 'noopener';
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
    return true;
  } catch {
    return false;
  }
}

function consentErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof StepUpCancelledError) return "Not saved. To record your consent, confirm it's you.";
  if (error instanceof EmployeeApiError) {
    switch (error.kind) {
      case 'access_proof_invalid':
        return 'That code did not match or expired. Open a fresh test PDF and enter the 6-character code shown inside it.';
      case 'disclosure_outdated':
        return 'The disclosure text was updated. Reload this page to review the latest wording before giving consent.';
      case 'no_active_consent':
        return 'Your electronic consent is already off. Paper delivery is active.';
      case 'offline':
        return "You're offline. Connect to Wi-Fi or data, then try again.";
      case 'rate_limited':
        return 'Too many tries. Wait a minute, then try again.';
      default:
        break;
    }
  }
  return fallback;
}

function DisclosureBody({ text }: { text: string }): ReactElement {
  const blocks = text.split(/\n\s*\n/).map((part) => part.trim()).filter(Boolean);
  return (
    <div className="emp-disclosure-box">
      {blocks.map((block, index) => {
        const lines = block.split('\n').map((line) => line.trim()).filter(Boolean);
        if (lines.length >= 2) {
          return (
            <div key={index} className="emp-disclosure-section">
              <h3 className="emp-disclosure-heading">{lines[0]}</h3>
              <p className="emp-disclosure-text">{lines.slice(1).join(' ')}</p>
            </div>
          );
        }
        return <p key={index} className="emp-disclosure-text">{block}</p>;
      })}
    </div>
  );
}

function guamLongDate(timestamp: string): string {
  const day = accessDay(timestamp);
  return day ? longDate(day) : '';
}

function statusChip(item: DeliveryConsentItem): ReactElement {
  if (item.status === 'consented') {
    return <Chip tone="good" icon={CheckCircle2}>Electronic consent on file</Chip>;
  }
  if (item.status === 'withdrawn') {
    return <Chip tone="neutral">Paper delivery (withdrawn)</Chip>;
  }
  return <Chip tone="neutral">Paper delivery</Chip>;
}

function ConsentCard({
  item,
  canConsent,
  canWithdraw,
  isPrintTarget,
  onPrint,
  onUpdated,
  onReload,
}: {
  item: DeliveryConsentItem;
  canConsent: boolean;
  canWithdraw: boolean;
  isPrintTarget: boolean;
  onPrint: () => void;
  onUpdated: (next: DeliveryConsentsState, message: string) => void;
  onReload: () => void;
}): ReactElement {
  const { api, state, reportError } = useReadySession();
  const { stepUp, openAccountSettings } = useEmployeeAuth();
  const copy = KIND_COPY[item.kind];
  const disclosure = item.disclosure;

  const [acknowledged, setAcknowledged] = useState(false);
  const [disclosureOpen, setDisclosureOpen] = useState(false);
  const [challenge, setChallenge] = useState<W2GuAccessProofChallenge | null>(null);
  const [proofCode, setProofCode] = useState('');
  const [loadingPdf, setLoadingPdf] = useState(false);
  const [saving, setSaving] = useState(false);
  const [confirmingWithdraw, setConfirmingWithdraw] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [needsTwoStep, setNeedsTwoStep] = useState(false);
  const [pdfNotice, setPdfNotice] = useState<string | null>(null);

  const isConsented = item.status === 'consented' && item.activeConsent !== null;
  const needsReconsent = isConsented && item.activeConsent && !item.activeConsent.matchesCurrentDisclosure;
  const showConsentForm = canConsent && disclosure !== null && (!isConsented || Boolean(needsReconsent));

  const openTestPdf = async (): Promise<void> => {
    setLoadingPdf(true);
    setError(null);
    setPdfNotice(null);
    try {
      const next = await api.startW2GuAccessProof(state.link.id);
      setChallenge(next);
      setProofCode('');
      const opened = openBase64Pdf(next.pdfBase64, next.filename);
      setPdfNotice(
        opened
          ? 'Test PDF downloaded. Open it and enter the 6-character code shown inside.'
          : 'Test PDF is ready, but your browser blocked the download. Try again or allow downloads.',
      );
    } catch (failure) {
      if (isSessionError(failure)) {
        reportError(failure);
      } else {
        setError(consentErrorMessage(failure, "Couldn't open the test PDF. Try again in a minute."));
      }
    } finally {
      setLoadingPdf(false);
    }
  };

  const giveConsent = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!disclosure) return;
    if (!acknowledged) {
      setError(`Confirm that you have read and agree to electronic delivery of your ${copy.shortLabel}.`);
      return;
    }
    if (item.requiresAccessProof && (!challenge || proofCode.trim().length < 6)) {
      setError('Open the test PDF first and enter the 6-character code shown inside it.');
      return;
    }

    setSaving(true);
    setError(null);
    setNeedsTwoStep(false);
    try {
      const next = await stepUp(() =>
        api.giveDeliveryConsent(state.link.id, {
          kind: item.kind,
          disclosureVersion: disclosure.version,
          disclosureDigest: disclosure.digest,
          ...(item.requiresAccessProof && challenge
            ? { accessProofToken: challenge.accessProofToken, accessProofCode: proofCode.trim() }
            : {}),
        }),
      );
      setAcknowledged(false);
      setChallenge(null);
      setProofCode('');
      setPdfNotice(null);
      onUpdated(next, `Consent recorded for electronic ${copy.shortLabel}. Paper copies still continue for now.`);
    } catch (failure) {
      if (failure instanceof EmployeeApiError && failure.kind === 'mfa_enrollment_required') {
        setNeedsTwoStep(true);
        setError('Not saved. Set up two-step sign-in first to record your consent.');
      } else if (isSessionError(failure)) {
        reportError(failure);
      } else {
        setError(consentErrorMessage(failure, "Couldn't save your consent. Try again in a minute."));
        if (failure instanceof EmployeeApiError && failure.kind === 'disclosure_outdated') {
          onReload();
        }
      }
    } finally {
      setSaving(false);
    }
  };

  const confirmWithdraw = async (): Promise<void> => {
    setSaving(true);
    setError(null);
    try {
      const next = await api.withdrawDeliveryConsent(state.link.id, item.kind);
      setConfirmingWithdraw(false);
      onUpdated(next, "Saved. You'll get paper copies.");
    } catch (failure) {
      if (isSessionError(failure)) {
        reportError(failure);
      } else {
        setError(consentErrorMessage(failure, "Couldn't withdraw consent. Try again in a minute."));
      }
    } finally {
      setSaving(false);
    }
  };

  const canSubmit = acknowledged && (!item.requiresAccessProof || (challenge !== null && proofCode.trim().length >= 6));
  // Consent is given only with the disclosure in view; it folds away after.
  const showDisclosure = showConsentForm || disclosureOpen || isPrintTarget;
  const disclosureId = `emp-disclosure-${item.kind}`;

  return (
    <Card
      title={copy.heading}
      className="emp-consent-card"
      data-print-target={isPrintTarget ? 'true' : undefined}
      action={(
        <div className="flex flex-wrap items-center justify-end gap-2">
          {disclosure?.draftMarker && (
            <Chip tone="warn" data-testid="draft-wording-marker">Draft wording</Chip>
          )}
          {statusChip(item)}
        </div>
      )}
    >
      <div className="space-y-4">
        {item.paperContinues && (
          <div className="emp-notice-inline" role="note">
            <p className="text-neutral-700">
              Paper copies continue for everyone for now. Your choice here records your preference for future electronic delivery.
            </p>
          </div>
        )}

        {isConsented && item.activeConsent && (
          <div className="space-y-2">
            <p className="text-neutral-700">
              Consent recorded on <strong>{guamLongDate(item.activeConsent.givenAt)}</strong> (version {item.activeConsent.disclosureVersion}).
            </p>
            {item.kind === 'w2gu' && item.emailNoticeLockedOn && (
              <p className="emp-inline-icon text-neutral-700">
                <Mail aria-hidden="true" className="size-5 shrink-0" />
                Tax document availability email notices stay on while electronic W-2GU consent is active.
              </p>
            )}
            {needsReconsent && (
              <div className="emp-notice-inline emp-notice-warn" role="note">
                <p className="text-neutral-800">Updated disclosure wording is available. Review and confirm below to update your consent.</p>
              </div>
            )}
          </div>
        )}

        {item.status === 'withdrawn' && item.lastWithdrawnAt && (
          <p className="text-neutral-700">
            You withdrew electronic consent on <strong>{guamLongDate(item.lastWithdrawnAt)}</strong>. Paper copies will continue.
          </p>
        )}

        {disclosure ? (
          <div className="space-y-3">
            <div className="emp-no-print flex flex-wrap items-center justify-between gap-2">
              {showConsentForm ? <span /> : (
                <button
                  type="button"
                  className="emp-disclosure-toggle"
                  aria-expanded={showDisclosure}
                  aria-controls={disclosureId}
                  onClick={() => setDisclosureOpen((open) => !open)}
                >
                  {showDisclosure ? 'Hide the disclosure' : 'Read the disclosure'}
                </button>
              )}
              <EmpButton
                variant="quiet"
                className="emp-btn-small"
                onClick={onPrint}
              >
                <Printer aria-hidden="true" className="size-4" />
                Print
              </EmpButton>
            </div>
            <div id={disclosureId} className="emp-disclosure-panel space-y-2" hidden={!showDisclosure}>
              <p className="emp-label-quiet">{disclosure.title}</p>
              <DisclosureBody text={disclosure.text} />
            </div>
          </div>
        ) : (
          <p className="text-neutral-600">Disclosure text is not available right now.</p>
        )}

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

        {showConsentForm && disclosure && (
          <form className="emp-form emp-no-print" onSubmit={(event) => { void giveConsent(event); }} noValidate>
            {item.requiresAccessProof && (
              <div className="emp-proof-box">
                <p className="font-bold text-neutral-900">Can you open this PDF?</p>
                <p className="text-neutral-700">
                  Before consenting to electronic Form W-2GU delivery, open the test PDF and enter the 6-character code shown inside it.
                </p>
                <EmpButton
                  variant="secondary"
                  className="emp-narrow-button"
                  block
                  onClick={() => { void openTestPdf(); }}
                  disabled={loadingPdf || saving}
                  aria-busy={loadingPdf}
                >
                  <FileText aria-hidden="true" className="size-5" />
                  {loadingPdf ? 'Preparing test PDF…' : challenge ? 'Open a new test PDF' : 'Open test PDF'}
                </EmpButton>
                {pdfNotice && <p className="emp-hint" role="status">{pdfNotice}</p>}
                {challenge && (
                  <Field
                    label="Code from the test PDF"
                    id={`emp-consent-proof-${item.kind}`}
                    value={proofCode}
                    onChange={(event) => setProofCode(event.target.value)}
                    placeholder="Example: K7M4RT"
                    autoCapitalize="characters"
                    autoCorrect="off"
                    spellCheck={false}
                    maxLength={12}
                    disabled={saving}
                  />
                )}
              </div>
            )}

            <label className="emp-checkbox-row" htmlFor={`emp-consent-agree-${item.kind}`}>
              <input
                id={`emp-consent-agree-${item.kind}`}
                type="checkbox"
                className="emp-checkbox"
                checked={acknowledged}
                onChange={(event) => setAcknowledged(event.target.checked)}
                disabled={saving}
              />
              <span>{copy.agreeLabel}</span>
            </label>

            <p className="emp-hint emp-inline-icon">
              <ShieldCheck aria-hidden="true" className="size-5 shrink-0" />
              To keep your account safe, we'll ask you to confirm it's you before recording consent.
            </p>

            <EmpButton
              type="submit"
              block
              className="emp-narrow-button"
              disabled={saving || !canSubmit}
              aria-busy={saving}
            >
              {saving ? 'Recording consent…' : `Consent to electronic ${copy.shortLabel}`}
            </EmpButton>
          </form>
        )}

        {canWithdraw && isConsented && (
          <div className="emp-no-print space-y-3 border-t border-neutral-200 pt-4">
            {confirmingWithdraw ? (
              <div className="emp-notice-inline emp-notice-warn space-y-3" role="region" aria-label="Confirm paper delivery">
                <p className="font-bold text-neutral-900">Switch back to paper {copy.shortLabel}?</p>
                <p className="text-neutral-700">
                  You'll get paper copies for future {copy.shortLabel}.
                </p>
                <div className="emp-form-buttons">
                  <EmpButton
                    variant="danger"
                    disabled={saving}
                    aria-busy={saving}
                    onClick={() => { void confirmWithdraw(); }}
                  >
                    {saving ? 'Switching to paper…' : 'Confirm paper delivery'}
                  </EmpButton>
                  <EmpButton variant="quiet" disabled={saving} onClick={() => setConfirmingWithdraw(false)}>
                    Keep electronic consent
                  </EmpButton>
                </div>
              </div>
            ) : (
              <EmpButton
                variant="secondary"
                className="emp-narrow-button"
                block
                disabled={saving}
                onClick={() => {
                  setError(null);
                  setConfirmingWithdraw(true);
                }}
              >
                Switch back to paper (withdraw consent)
              </EmpButton>
            )}
          </div>
        )}
      </div>
    </Card>
  );
}

function DeliveryConsentCards({ kinds }: { kinds: readonly DeliveryConsentKind[] }): ReactElement | null {
  const { isFormer, isViewOnly } = useReadySession();
  const { state, reload, update } = useEmployeeData<DeliveryConsentsState>(
    'delivery-consents',
    (api, linkId, signal) => api.deliveryConsents(linkId, signal),
  );
  const [notice, setNotice] = useState<string | null>(null);
  const [printingKind, setPrintingKind] = useState<DeliveryConsentKind | null>(null);

  useEffect(() => {
    if (!printingKind) return undefined;
    document.body.classList.add('emp-printing-disclosure');
    const clear = (): void => {
      document.body.classList.remove('emp-printing-disclosure');
      setPrintingKind(null);
    };
    window.addEventListener('afterprint', clear);
    window.print();
    return () => {
      window.removeEventListener('afterprint', clear);
      document.body.classList.remove('emp-printing-disclosure');
    };
  }, [printingKind]);

  if (state.status === 'loading') return <Card><SkeletonRows rows={3} label="Loading electronic delivery preferences" /></Card>;
  if (state.status === 'error') return <Card><LoadProblem kind={state.kind} onRetry={reload} what="electronic delivery preferences" /></Card>;

  const visible = kinds
    .map((kind) => state.data.consents.find((entry) => entry.kind === kind))
    .filter((entry): entry is DeliveryConsentItem => Boolean(entry));

  if (visible.length === 0) return null;

  const canConsent = !isFormer && !isViewOnly;
  const canWithdraw = !isViewOnly;

  return (
    <>
      {notice && (
        <div className="emp-span-all emp-no-print">
          <FormMessage tone="good">{notice}</FormMessage>
        </div>
      )}
      {visible.map((item) => (
        <ConsentCard
          key={item.kind}
          item={item}
          canConsent={canConsent}
          canWithdraw={canWithdraw}
          isPrintTarget={printingKind === item.kind}
          onPrint={() => setPrintingKind(item.kind)}
          onReload={reload}
          onUpdated={(next, message) => {
            update(next);
            setNotice(message);
          }}
        />
      ))}
    </>
  );
}

export function DeliveryConsentSection({ kinds }: { kinds: readonly DeliveryConsentKind[] }): ReactElement | null {
  const { state: session } = useReadySession();
  if (!session.info.features.deliveryConsent) return null;
  return <DeliveryConsentCards kinds={kinds} />;
}
