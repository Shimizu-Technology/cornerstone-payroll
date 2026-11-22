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
    ...history.pay_rate_changes.map((change) => ({
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

export function PayRateHistory({ history }: { history: EmployeeCompensationHistory }) {
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
        <div className="space-y-3 sm:hidden">
          {rows.map((row) => (
            <MobileRecordCard key={row.key} tone={row.status === 'current' ? 'primary' : 'default'}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <p className="text-sm font-semibold text-neutral-900">{row.change}</p>
                <StatusBadges row={row} />
              </div>
              <div className="mt-3 grid grid-cols-1 gap-3">
                <MobileField label="In effect" value={dates(row)} />
                <MobileField label="Reason" value={row.reason} />
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
