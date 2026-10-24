import type { InvitationDeliveryResponse } from '@/services/api';

export function invitationOutcomeMessage(response: InvitationDeliveryResponse): string {
  switch (response.invitation_delivery_status) {
    case 'captured': return 'Captured in staging (not sent).';
    case 'queued': return 'Invitation queued for email delivery.';
    case 'submitted': return 'Invitation submitted to the email provider.';
    case 'failed': return `Invitation email failed${response.invitation_error ? `: ${response.invitation_error}` : ''}. You can retry from the user list.`;
    case 'not_requested': return '';
    default: return 'Invitation delivery status is unavailable. Check the user before retrying.';
  }
}
