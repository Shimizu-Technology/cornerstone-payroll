// Wording shared by the consent cards (consent.tsx) and the "Go paperless?"
// step (paperless.tsx), kept out of those files so they export only components.
import { EmployeeApiError, StepUpCancelledError } from './api';
import type { DeliveryConsentKind } from './contracts';

export const KIND_COPY: Record<DeliveryConsentKind, { heading: string; shortLabel: string; agreeLabel: string }> = {
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

export function consentErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof StepUpCancelledError) return "Not saved. To record your consent, confirm it's you.";
  if (error instanceof EmployeeApiError) {
    switch (error.kind) {
      case 'access_proof_invalid':
        return 'That code did not match or expired. Open a fresh test PDF and enter the 6-character code shown inside it.';
      case 'disclosure_outdated':
        return 'The disclosure text was updated. Reload this page to review the latest wording before giving consent.';
      case 'no_active_consent':
        return 'Your electronic consent is already off. Paper delivery is active.';
      case 'consent_active':
        return 'Your electronic consent is already on. To switch back to paper, use My info.';
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
