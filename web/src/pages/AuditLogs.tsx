import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { auditLogsApi, usersApi } from '@/services/api';
import type { AuditLogEntry } from '@/services/api';
import type { User } from '@/types';
import { Button } from '@/components/ui/button';
import { ArrowDownUp, ChevronLeft, ChevronRight, Download } from 'lucide-react';

const FIELD_LABELS: Record<string, string> = {
  wage_rates: 'Wage rates',
  pay_rate: 'Pay rate',
  additional_withholding: 'Additional withholding',
  filing_status: 'Filing status',
  employment_type: 'Employment type',
  salary_type: 'Salary type',
  pay_frequency: 'Pay frequency',
  address_line1: 'Address line 1',
  address_line2: 'Address line 2',
  date_of_birth: 'Date of birth',
  hire_date: 'Hire date',
  termination_date: 'Termination date',
  ssn_encrypted: 'SSN',
};

function humanizeKey(value: string) {
  return FIELD_LABELS[value] || value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function formatAction(action: string) {
  const [area, verb] = action.split('#');
  const cleanedArea = area.replace(/^client_/, 'client ').replace(/^admin_/, 'admin ').replace(/\//g, ' ').replace(/_/g, ' ');
  return `${humanizeKey(cleanedArea)} ${verb ? verb.replace(/_/g, ' ') : ''}`.trim();
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : value.toFixed(2);
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    if (value.length === 0) return 'None';
    return value
      .map((item) => {
        if (typeof item === 'object' && item !== null) {
          return Object.entries(item as Record<string, unknown>)
            .map(([key, nested]) => `${humanizeKey(key)}: ${formatValue(nested)}`)
            .join(' • ');
        }
        return formatValue(item);
      })
      .join('\n');
  }
  if (typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>)
      .map(([key, nested]) => `${humanizeKey(key)}: ${formatValue(nested)}`)
      .join('\n');
  }
  return String(value);
}

export function AuditLogs() {
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionFilter, setActionFilter] = useState('');
  const [recordTypeFilter, setRecordTypeFilter] = useState('');
  const [userFilter, setUserFilter] = useState<string>('');
  const [fromFilter, setFromFilter] = useState<string>('');
  const [toFilter, setToFilter] = useState<string>('');
  const [users, setUsers] = useState<User[]>([]);
  const [selectedLogId, setSelectedLogId] = useState<number | null>(null);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [total, setTotal] = useState(0);
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [isExporting, setIsExporting] = useState(false);
  const latestRequestId = useRef(0);

  const fetchLogs = useCallback(async () => {
    const requestId = ++latestRequestId.current;
    setIsLoading(true);
    setError(null);
    try {
      const response = await auditLogsApi.list({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        page,
        per_page: 50,
        sort_direction: sortDirection,
      });
      if (requestId !== latestRequestId.current) return;

      setLogs(response.data);
      setTotalPages(response.meta.total_pages || 1);
      setTotal(response.meta.total_count);
      setSelectedLogId((current) => response.data.find((log) => log.id === current)?.id || response.data[0]?.id || null);
    } catch (err) {
      if (requestId !== latestRequestId.current) return;

      setError(err instanceof Error ? err.message : 'Failed to load audit logs');
    } finally {
      if (requestId === latestRequestId.current) setIsLoading(false);
    }
  }, [actionFilter, recordTypeFilter, userFilter, fromFilter, toFilter, page, sortDirection]);

  const handleExport = async () => {
    setIsExporting(true);
    setError(null);
    try {
      const result = await auditLogsApi.exportCsv({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        sort_direction: sortDirection,
      });
      const url = URL.createObjectURL(result.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = result.filename || 'audit-history.csv';
      anchor.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to export audit history');
    } finally {
      setIsExporting(false);
    }
  };

  const fetchUsers = useCallback(async () => {
    try {
      const response = await usersApi.list();
      setUsers(response.data);
    } catch {
      setUsers([]);
    }
  }, []);

  useEffect(() => {
    void fetchLogs();
  }, [fetchLogs]);

  useEffect(() => {
    void fetchUsers();
  }, [fetchUsers]);

  const selectedLog = useMemo(
    () => logs.find((log) => log.id === selectedLogId) || null,
    [logs, selectedLogId]
  );

  const changedFields = Array.isArray(selectedLog?.metadata?.changed_fields)
    ? selectedLog.metadata.changed_fields.filter((field): field is string => typeof field === 'string')
    : [];

  const beforeValues = (selectedLog?.metadata?.before_values as Record<string, unknown> | undefined) || {};
  const afterValues = (selectedLog?.metadata?.after_values as Record<string, unknown> | undefined) || {};
  const detailEntries = Object.entries(selectedLog?.metadata || {}).filter(
    ([key]) => !['changed_fields', 'before_values', 'after_values'].includes(key)
  );

  return (
    <div>
      <Header title="Audit Logs" description="Track who changed what, when it happened, and what changed." />

      <div className="p-4 sm:p-6 lg:p-8">
        <Card className="mb-4 p-4">
          <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="font-semibold text-neutral-950">Complete activity history</p>
              <p className="text-sm text-neutral-500">{total.toLocaleString()} recorded actions across the organization</p>
            </div>
            <div className="flex gap-2">
              <Button
                variant="outline"
                onClick={() => {
                  setSortDirection((value) => value === 'desc' ? 'asc' : 'desc');
                  setPage(1);
                }}
              >
                <ArrowDownUp className="mr-2 h-4 w-4" />
                {sortDirection === 'desc' ? 'Newest first' : 'Oldest first'}
              </Button>
              <Button variant="outline" onClick={() => void handleExport()} disabled={isExporting}>
                <Download className="mr-2 h-4 w-4" />
                {isExporting ? 'Exporting...' : 'Export CSV'}
              </Button>
            </div>
          </div>
          <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
            <Input
              placeholder="Search actions"
              value={actionFilter}
              onChange={(e) => {
                setActionFilter(e.target.value);
                setPage(1);
              }}
            />
            <Input
              placeholder="Search records"
              value={recordTypeFilter}
              onChange={(e) => {
                setRecordTypeFilter(e.target.value);
                setPage(1);
              }}
            />
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm"
              value={userFilter}
              onChange={(e) => {
                setUserFilter(e.target.value);
                setPage(1);
              }}
            >
              <option value="">All users</option>
              {users.map((user) => (
                <option key={user.id} value={user.id}>
                  {user.name} ({user.email})
                </option>
              ))}
            </select>
          </div>
          <div className="mt-3 grid grid-cols-1 gap-3 md:grid-cols-2">
            <Input
              type="datetime-local"
              value={fromFilter}
              onChange={(e) => {
                setFromFilter(e.target.value);
                setPage(1);
              }}
            />
            <Input
              type="datetime-local"
              value={toFilter}
              onChange={(e) => {
                setToFilter(e.target.value);
                setPage(1);
              }}
            />
          </div>
        </Card>

        {error && <div className="mb-4 text-sm text-danger-600">{error}</div>}

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="text-center">
              <div className="mx-auto h-8 w-8 animate-spin rounded-full border-b-2 border-primary-600" />
              <p className="mt-2 text-sm text-gray-500">Loading logs...</p>
            </div>
          </div>
        ) : (
          <div className="grid gap-6 xl:grid-cols-[minmax(0,1.15fr)_minmax(320px,0.85fr)]">
            <Card>
              <div className="space-y-3 p-3 sm:hidden">
                {logs.map((log) => (
                  <MobileRecordCard
                    key={log.id}
                    tone={selectedLogId === log.id ? 'primary' : 'default'}
                    onClick={() => setSelectedLogId(log.id)}
                  >
                    <p className="font-semibold text-neutral-950">{formatAction(log.action)}</p>
                    <p className="mt-1 text-sm text-neutral-500">
                      {log.user_name || 'System'} • {new Date(log.created_at).toLocaleString()}
                    </p>
                    <div className="mt-4 grid grid-cols-2 gap-3">
                      <MobileField label="Record" value={`${humanizeKey(log.record_type || 'General')}${log.record_id ? ` #${log.record_id}` : ''}`} />
                      <MobileField label="IP" value={log.ip_address || '—'} />
                    </div>
                  </MobileRecordCard>
                ))}
              </div>
              <div className="hidden sm:block">
                <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Time</TableHead>
                    <TableHead>User</TableHead>
                    <TableHead>Action</TableHead>
                    <TableHead>Record</TableHead>
                    <TableHead>IP</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {logs.map((log) => (
                    <TableRow
                      key={log.id}
                      className={selectedLogId === log.id ? 'bg-primary-50/70' : 'cursor-pointer'}
                      onClick={() => setSelectedLogId(log.id)}
                    >
                      <TableCell>{new Date(log.created_at).toLocaleString()}</TableCell>
                      <TableCell>{log.user_name || 'System'}</TableCell>
                      <TableCell>{formatAction(log.action)}</TableCell>
                      <TableCell>
                        {humanizeKey(log.record_type || 'General')}
                        {log.record_id ? ` #${log.record_id}` : ''}
                      </TableCell>
                      <TableCell>{log.ip_address || '—'}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
                </Table>
              </div>
              {totalPages > 1 && (
                <div className="flex items-center justify-between border-t border-neutral-200 px-4 py-3">
                  <p className="text-sm text-neutral-500">Page {page} of {totalPages}</p>
                  <div className="flex gap-2">
                    <Button size="sm" variant="outline" onClick={() => setPage((value) => Math.max(1, value - 1))} disabled={page === 1}>
                      <ChevronLeft className="mr-1 h-4 w-4" /> Previous
                    </Button>
                    <Button size="sm" variant="outline" onClick={() => setPage((value) => Math.min(totalPages, value + 1))} disabled={page === totalPages}>
                      Next <ChevronRight className="ml-1 h-4 w-4" />
                    </Button>
                  </div>
                </div>
              )}
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{selectedLog ? 'Selected Activity' : 'Activity Details'}</CardTitle>
              </CardHeader>
              <CardContent className="space-y-5">
                {selectedLog ? (
                  <>
                    <div className="rounded-2xl border border-neutral-200 bg-neutral-50 px-4 py-4">
                      <p className="text-lg font-semibold text-neutral-900">{formatAction(selectedLog.action)}</p>
                      <p className="mt-1 text-sm text-neutral-500">
                        {selectedLog.user_name || 'System'} • {new Date(selectedLog.created_at).toLocaleString()}
                      </p>
                    </div>

                    <DetailList
                      rows={[
                        ['Person', selectedLog.user_name || 'System'],
                        ['Actor email', selectedLog.actor_email || '—'],
                        ['Role', selectedLog.actor_role ? humanizeKey(selectedLog.actor_role) : '—'],
                        ['Record', `${humanizeKey(selectedLog.record_type || 'General')}${selectedLog.record_id ? ` #${selectedLog.record_id}` : ''}`],
                        ['Subject', selectedLog.subject_name || '—'],
                        ['Client', selectedLog.company_name || 'Organization-wide'],
                        ['Source', formatValue(selectedLog.metadata?.source)],
                        ['Address', selectedLog.ip_address || '—'],
                      ]}
                    />

                    {detailEntries.length > 0 ? (
                      <div>
                        <p className="text-sm font-medium text-neutral-900">Details</p>
                        <div className="mt-3 space-y-3">
                          {detailEntries.map(([key, value]) => (
                            <div key={key} className="rounded-xl border border-neutral-200 px-4 py-3">
                              <p className="text-sm font-medium text-neutral-900">{humanizeKey(key)}</p>
                              <p className="mt-1 whitespace-pre-wrap text-sm text-neutral-600">{formatValue(value)}</p>
                            </div>
                          ))}
                        </div>
                      </div>
                    ) : null}

                    {changedFields.length > 0 ? (
                      <div>
                        <p className="text-sm font-medium text-neutral-900">What changed</p>
                        <div className="mt-3 space-y-3">
                          {changedFields.map((field) => (
                            <div key={field} className="rounded-2xl border border-neutral-200 bg-white p-4">
                              <p className="text-sm font-semibold text-neutral-900">{humanizeKey(field)}</p>
                              <div className="mt-3 grid gap-3 md:grid-cols-2">
                                <ValueCard label="Before" value={beforeValues[field]} />
                                <ValueCard label="After" value={afterValues[field]} />
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    ) : null}
                  </>
                ) : (
                  <p className="text-sm text-neutral-500">Select an audit entry to see the full activity details.</p>
                )}
              </CardContent>
            </Card>
          </div>
        )}
      </div>
    </div>
  );
}

function DetailList({ rows }: { rows: Array<[string, string]> }) {
  return (
    <div className="space-y-3">
      {rows.map(([label, value]) => (
        <div key={label} className="flex items-start justify-between gap-4 rounded-xl border border-neutral-200 px-4 py-3">
          <p className="text-sm font-medium text-neutral-500">{label}</p>
          <p className="text-right text-sm text-neutral-900">{value}</p>
        </div>
      ))}
    </div>
  );
}

function ValueCard({ label, value }: { label: string; value: unknown }) {
  return (
    <div className="rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3">
      <p className="text-xs font-semibold uppercase tracking-[0.14em] text-neutral-500">{label}</p>
      <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-neutral-800">{formatValue(value)}</p>
    </div>
  );
}
