import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency, formatDate } from '@/lib/utils';
import type { CompensationVersionStatus, EmployeeCompensationHistory, EmployeePayRateChange, EmployeeWageRateVersion } from '@/types';

const SOURCE_LABELS: Record<string, string> = {
  backfill: 'Existing setup',
  employee_creation: 'New employee',
  staff: 'Payroll staff',
  client_approved: 'Approved client request',
  client_portal: 'Client portal',
  wage_rate_created: 'Rate added',
  go_live_setup_transfer: 'Go-live setup',
  quickbooks_history: 'QuickBooks setup',
  bulk_import: 'Employee import',
  classification_transition: 'Classification change',
  one_off_payee: '1099 payee',
  copied_setup: 'Copied setup',
  rollout_reconciliation: 'Release reconciliation',
  data_config_task: 'Data setup',
};

const STATUS: Record<CompensationVersionStatus, { label: string; variant: 'success' | 'info' | 'default' }> = {
  current: { label: 'Current', variant: 'success' },
  scheduled: { label: 'Scheduled', variant: 'info' },
  past: { label: 'Past', variant: 'default' },
};

interface HistoryRow {
  key: string;
  effectiveOn: string;
  endsOn: string | null;
  status: CompensationVersionStatus;
  change: string;
  reason: string;
  source: string;
  historicalCorrection: boolean;
  recordedBy?: string | null;
}

function payRateText(change: EmployeePayRateChange): string {
  const amount = formatCurrency(Number(change.pay_rate) || 0);
  if (change.employment_type === 'salary') {
    if (change.salary_type === 'variable') return 'Variable salary (set each payroll)';
    return change.salary_type === 'per_period' ? `Salary ${amount} per pay period` : `Salary ${amount} per year`;
  }
  if (change.employment_type === 'contractor' && change.contractor_pay_type !== 'hourly') return `Contractor fee ${amount} per pay period`;
  return `Pay rate ${amount}/hr`;
}

function wageRateText(version: EmployeeWageRateVersion): string {
  if (!version.active) return `${version.label}: ended`;
  const amount = version.rate === null ? 'no rate' : `${formatCurrency(Number(version.rate) || 0)}/hr`;
  return `${version.label}${version.is_primary ? ' (primary)' : ''}: ${amount}`;
}

function payRateHistoryRows(history: EmployeeCompensationHistory): HistoryRow[] {
  const rows: HistoryRow[] = [
    ...history.pay_rate_changes.filter((change, index) => {
      const prior = history.pay_rate_changes[index + 1];
      const sameBasis = !prior || (prior.employment_type === change.employment_type && prior.salary_type === change.salary_type
        && prior.pay_frequency === change.pay_frequency && prior.contractor_pay_type === change.contractor_pay_type);
      const hourly = change.employment_type === 'hourly' || (change.employment_type === 'contractor' && change.contractor_pay_type === 'hourly');
      const active = history.wage_rate_versions.filter((rate) => rate.active && rate.effective_on <= change.effective_on
        && (!rate.ends_on || rate.ends_on >= change.effective_on));
      const duplicate = active.length === 1 && active[0].effective_on === change.effective_on
        && active[0].rate !== null && Number(active[0].rate) === Number(change.pay_rate)
        && (active[0].reason === change.reason || (active[0].source === 'backfill' && change.source === 'backfill'));
      return !(sameBasis && hourly && duplicate);
    }).map((change) => ({
      key: `pay-${change.id}`,
      effectiveOn: change.effective_on,
      endsOn: change.ends_on,
      status: change.status,
      change: payRateText(change),
      reason: change.reason,
      source: change.source,
      historicalCorrection: change.historical_correction,
      recordedBy: change.created_by_name,
    })),
    ...history.wage_rate_versions.map((version) => ({
      key: `wage-${version.id}`,
      effectiveOn: version.effective_on,
      endsOn: version.ends_on,
      status: version.status,
      change: wageRateText(version),
      reason: version.reason,
      source: version.source,
      historicalCorrection: version.historical_correction,
      recordedBy: version.created_by_name,
    })),
  ];
  return rows.sort((a, b) => b.effectiveOn.localeCompare(a.effectiveOn) || a.key.localeCompare(b.key));
}

function dates(row: HistoryRow): string {
  return row.endsOn ? `${formatDate(row.effectiveOn)} – ${formatDate(row.endsOn)}` : `${formatDate(row.effectiveOn)} onward`;
}

function sourceText(row: HistoryRow): string {
  const source = SOURCE_LABELS[row.source] || row.source.replaceAll('_', ' ');
  return row.recordedBy ? `${source} · ${row.recordedBy}` : source;
}

function StatusBadges({ row }: { row: HistoryRow }) {
  return (
    <span className="inline-flex flex-wrap gap-1">
      <Badge variant={STATUS[row.status].variant}>{STATUS[row.status].label}</Badge>
      {row.historicalCorrection && <Badge variant="warning">Historical correction</Badge>}
    </span>
  );
}

export function PayRateHistory({ history, onCancel }: {
  history: EmployeeCompensationHistory;
  onCancel?: (date: string, reason: string) => Promise<void>;
}) {
  const [cancellation, setCancellation] = useState<{ date: string; reason: string } | null>(null);
  const [cancelError, setCancelError] = useState('');
  const [cancelling, setCancelling] = useState(false);
  const scheduledDates = [...new Set([...history.pay_rate_changes, ...history.wage_rate_versions]
    .filter((version) => version.status === 'scheduled').map((version) => version.effective_on))].sort();

  const confirmCancellation = async () => {
    if (!onCancel || !cancellation?.reason.trim()) return;
    setCancelling(true);
    setCancelError('');
    try {
      await onCancel(cancellation.date, cancellation.reason.trim());
      setCancellation(null);
    } catch (error) {
      setCancelError(error instanceof Error ? error.message : 'Unable to cancel this scheduled change.');
    } finally {
      setCancelling(false);
    }
  };
  const rows = payRateHistoryRows(history);
  if (rows.length === 0) return null;

  return (
    <Card className="mb-6" data-testid="pay-rate-history">
      <CardHeader>
        <CardTitle>Pay rate history</CardTitle>
        <CardDescription>
          Each change starts on its effective date. Payroll uses the rate in effect on the pay period end date, and paid checks keep the rate they were paid at.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {onCancel && scheduledDates.length > 0 && (
          <div className="mb-4 flex flex-wrap gap-2">
            {scheduledDates.map((date) => (
              <Button key={date} type="button" variant="outline" size="sm" disabled={cancelling}
                onClick={() => { setCancelError(''); setCancellation({ date, reason: '' }); }}>
                Cancel change for {formatDate(date)}
              </Button>
            ))}
          </div>
        )}
        {cancellation && (
          <fieldset className="mb-4 space-y-2 rounded-lg border border-neutral-200 p-3">
            <legend className="px-1 text-sm font-semibold">Cancel all pay changes for {formatDate(cancellation.date)}</legend>
            <label className="block text-sm" htmlFor="scheduled-pay-cancellation-reason">Reason for cancelling</label>
            <Input id="scheduled-pay-cancellation-reason" value={cancellation.reason} disabled={cancelling}
              onChange={(event) => setCancellation({ ...cancellation, reason: event.target.value })} />
            {cancelError && <p className="text-sm text-danger-600" role="alert">{cancelError}</p>}
            <div className="flex flex-wrap gap-2">
              <Button type="button" disabled={!cancellation.reason.trim() || cancelling} onClick={() => void confirmCancellation()}>
                {cancelling ? 'Cancelling…' : 'Confirm cancellation'}
              </Button>
              <Button type="button" variant="outline" disabled={cancelling} onClick={() => setCancellation(null)}>Keep scheduled change</Button>
            </div>
          </fieldset>
        )}
        <div className="space-y-3 sm:hidden">
          {rows.map((row) => (
            <MobileRecordCard key={row.key} tone={row.status === 'current' ? 'primary' : 'default'}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <p className="min-w-0 break-words text-sm font-semibold text-neutral-900">{row.change}</p>
                <StatusBadges row={row} />
              </div>
              <div className="mt-3 grid grid-cols-1 gap-3">
                <MobileField label="In effect" value={dates(row)} />
                <MobileField label="Reason" value={<span className="break-words">{row.reason}</span>} />
                <MobileField label="Recorded by" value={sourceText(row)} />
              </div>
            </MobileRecordCard>
          ))}
        </div>
        <Table containerClassName="hidden sm:block">
          <TableHeader>
            <TableRow>
              <TableHead>In effect</TableHead>
              <TableHead>Change</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Reason</TableHead>
              <TableHead>Recorded by</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.key}>
                <TableCell className="whitespace-nowrap">{dates(row)}</TableCell>
                <TableCell className="font-medium text-neutral-900">{row.change}</TableCell>
                <TableCell><StatusBadges row={row} /></TableCell>
                <TableCell className="text-neutral-700">{row.reason}</TableCell>
                <TableCell className="text-neutral-600">{sourceText(row)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  );
}
