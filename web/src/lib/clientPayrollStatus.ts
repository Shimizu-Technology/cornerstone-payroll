const labels: Record<string, string> = {
  pending: 'Ready for your review',
  approved: 'Client approved',
  changes_requested: 'Changes requested',
  committed: 'Finalized',
  locked: 'Imported (read-only)',
};

export function clientPayrollStatus(status?: string | null): string {
  return (status && labels[status]) || 'Being prepared';
}

export function clientPayRunStatus(period: {
  status: string;
  test_workspace_role?: string | null;
  client_review_status?: string | null;
}): string {
  if (period.status === 'committed' || period.test_workspace_role === 'baseline') return clientPayrollStatus('committed');
  return clientPayrollStatus(period.client_review_status ??
    (period.status === 'approved' ? 'preparing' : period.status));
}
