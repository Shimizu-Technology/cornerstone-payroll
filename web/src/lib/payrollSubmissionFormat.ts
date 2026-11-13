import type { SubmissionStatus, ChangeRow, PeriodSummary } from '@/services/payrollSubmissions';

export function formatGuam(value?: string | null): string {
  if (!value) return '';
  return new Date(value).toLocaleString('en-US', { timeZone: 'Pacific/Guam', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

export function formatDate(value?: string | null): string {
  if (!value) return '';
  return new Date(`${value}T00:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
}

export function statusVariant(status: SubmissionStatus): 'default' | 'success' | 'warning' | 'info' | 'danger' {
  if (status === 'paid' || status === 'approved') return 'success';
  if (status === 'changes_requested') return 'warning';
  if (status === 'waiting_for_files') return 'default';
  return 'info';
}

export function changeSummary(row: ChangeRow): string {
  const who = row.employee_name || (row.employee_names?.length ? row.employee_names.join(', ') : '');
  const parts: string[] = [];
  switch (row.kind) {
    case 'extra_hours': parts.push(`${row.hours} hours`); break;
    case 'paid_leave': parts.push(`${row.hours} hours paid leave`); break;
    case 'owner_pay': parts.push(`$${row.amount} ${row.basis === 'each' ? 'for each owner' : 'total'}`); break;
    case 'new_hire': parts.push(`${row.name}, starting at $${row.starting_wage} ${row.wage_unit === 'salary' ? 'salary' : 'per hour'}`); if (row.start_date) parts.push(`starts ${formatDate(row.start_date)}`); break;
    case 'wage_change': parts.push(`new wage $${row.new_wage} ${row.wage_unit === 'salary' ? 'salary' : 'per hour'}`); if (row.effective_date) parts.push(`from ${formatDate(row.effective_date)}`); break;
    case 'deduction': parts.push(`${row.deduction_action} ${row.description}`); if (row.amount) parts.push(`$${row.amount}`); break;
    case 'direct_deposit_addition': parts.push('add to direct deposit'); break;
  }
  return [who, ...parts].filter(Boolean).join(' · ');
}

// Newest first. The period the client most likely needs to act on comes first, then any open one,
// then the next one coming up.
const CLIENT_TURN = new Set(['waiting_for_files', 'changes_requested', 'draft_ready']);

export function currentSubmissionPeriod(rows: PeriodSummary[]): PeriodSummary | null {
  return rows.find(row => row.open_for_files && CLIENT_TURN.has(row.status))
    ?? rows.find(row => row.open_for_files && row.status !== 'paid')
    // Rows arrive newest first; the next period to open is the earliest unpaid one.
    ?? [...rows].reverse().find(row => row.status !== 'paid')
    ?? rows[0]
    ?? null;
}
