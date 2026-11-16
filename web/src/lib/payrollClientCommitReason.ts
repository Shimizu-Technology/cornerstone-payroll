import type { PayPeriod } from '@/types';

export function payrollClientCommitReason(period: Pick<PayPeriod, 'payroll_review' | 'client_payroll_approval_required'>): string | undefined {
  const review = period.payroll_review;
  if (review?.status === 'changes_requested' || review?.changes_requested_at && review.status === 'pending') {
    return `${review.changes_requested_by_name || 'Client'} requested changes: ${review.change_request_note}. Unapprove to make changes.`;
  }
  if (period.client_payroll_approval_required && (review?.status !== 'approved' || !review.published_at)) {
    return 'Client approval is required for this revision before commit.';
  }
}
