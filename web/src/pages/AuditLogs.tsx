import { useState, useEffect, useCallback, useMemo, useRef, type ReactElement } from 'react';
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
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import type { User } from '@/types';
import { Button } from '@/components/ui/button';
import { ArrowDownUp, ChevronDown, ChevronLeft, ChevronRight, ClipboardList, Download, RotateCcw, TriangleAlert } from 'lucide-react';

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

function displayAction(log: AuditLogEntry) {
  return log.display_action || formatAction(log.action);
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

export function AuditLogs(): ReactElement {
  const { activeCompanyId } = useCompany();

  return <CompanyActivityHistory key={activeCompanyId ?? 'unselected'} />;
}

function CompanyActivityHistory(): ReactElement {
  const { isAdmin } = useAuth();
  const { activeCompany } = useCompany();
  const activeCompanyId = activeCompany?.id ?? null;
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
  const [exportError, setExportError] = useState<string | null>(null);
  const latestRequestId = useRef(0);

  const fetchLogs = useCallback(async () => {
    const requestId = ++latestRequestId.current;
    let keepLoadingForPageReset = false;
    setIsLoading(true);
    setError(null);
    try {
      const response = await auditLogsApi.list({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: isAdmin && userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        page,
        per_page: 50,
        sort_direction: sortDirection,
        company_id: isAdmin ? undefined : activeCompanyId ?? undefined,
      });
      if (requestId !== latestRequestId.current) return;

      if (response.data.length === 0 && page > 1) {
        keepLoadingForPageReset = true;
        setPage(1);
        return;
      }

      setLogs(response.data);
      setTotalPages(response.meta.total_pages || 1);
      setTotal(response.meta.total_count);
      setSelectedLogId((current) => response.data.find((log) => log.id === current)?.id || response.data[0]?.id || null);
    } catch (err) {
      if (requestId !== latestRequestId.current) return;

      setError(err instanceof Error ? err.message : 'Failed to load audit logs');
    } finally {
      if (requestId === latestRequestId.current && !keepLoadingForPageReset) setIsLoading(false);
    }
  }, [actionFilter, activeCompanyId, isAdmin, recordTypeFilter, userFilter, fromFilter, toFilter, page, sortDirection]);

  const handleExport = async () => {
    setIsExporting(true);
    setExportError(null);
    try {
      const result = await auditLogsApi.exportCsv({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: isAdmin && userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        sort_direction: sortDirection,
        company_id: isAdmin ? undefined : activeCompanyId ?? undefined,
      });
      const url = URL.createObjectURL(result.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = result.filename || 'audit-history.csv';
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
    } catch (err) {
      setExportError(err instanceof Error ? err.message : 'Failed to export audit history');
    } finally {
      setIsExporting(false);
    }
  };

  const fetchUsers = useCallback(async () => {
    if (!isAdmin) {
      setUsers([]);
      return;
    }

    try {
      const response = await usersApi.list();
      setUsers(response.data);
    } catch {
      setUsers([]);
    }
  }, [isAdmin]);

  useEffect(() => {
    void fetchLogs();
  }, [fetchLogs]);

  useEffect(() => {
    void fetchUsers();
  }, [fetchUsers]);

  const hasActiveFilters = Boolean(actionFilter || recordTypeFilter || (isAdmin && userFilter) || fromFilter || toFilter);

  const clearFilters = (): void => {
    setActionFilter('');
    setRecordTypeFilter('');
    setUserFilter('');
    setFromFilter('');
    setToFilter('');
    setPage(1);
  };

  const selectedLog = useMemo(
    () => logs.find((log) => log.id === selectedLogId) || null,
    [logs, selectedLogId]
  );

  const changedFields = Array.isArray(selectedLog?.metadata?.changed_fields)
    ? selectedLog.metadata.changed_fields.filter((field): field is string => typeof field === 'string' && field !== 'id')
    : [];
  const redactedFields = Array.isArray(selectedLog?.metadata?.redacted_fields)
    ? selectedLog.metadata.redacted_fields.filter((field): field is string => typeof field === 'string')
    : [];

  const beforeValues = (selectedLog?.metadata?.before_values as Record<string, unknown> | undefined) || {};
  const afterValues = (selectedLog?.metadata?.after_values as Record<string, unknown> | undefined) || {};
  const detailEntries = Object.entries(selectedLog?.metadata || {}).filter(
    ([key]) => !['changed_fields', 'before_values', 'after_values'].includes(key)
  );

  return (
    <div>
      <Header title="Activity History" description="Track who changed what, when it happened, and what changed." />

      <div className="p-4 sm:p-6 lg:p-8">
        <Card className="mb-4 p-4">
          <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="font-semibold text-neutral-950">{isAdmin ? 'Complete activity history' : 'Client activity history'}</p>
              <p className="text-sm text-neutral-500">
                {total.toLocaleString()} recorded actions {isAdmin ? 'across the organization' : `for ${activeCompany?.name || 'the selected client'}`}
              </p>
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
          {exportError && (
            <p className="mb-4 rounded-xl bg-danger-50 px-4 py-4 text-sm text-danger-700" role="alert">
              {exportError}
            </p>
          )}
          <div className={`grid grid-cols-1 gap-4 ${isAdmin ? 'md:grid-cols-3' : 'md:grid-cols-2'}`}>
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
            {isAdmin && <select
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
            </select>}
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

        {error ? (
          <Card className="flex min-h-72 flex-col items-center justify-center border-danger-200 p-8 text-center">
            <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-danger-50 text-danger-700">
              <TriangleAlert className="h-6 w-6" aria-hidden="true" />
            </div>
            <h2 className="mt-4 text-lg font-semibold text-neutral-950">Activity history could not be loaded</h2>
            <p className="mt-2 max-w-md text-sm text-neutral-500">{error}</p>
            <Button className="mt-4" variant="outline" onClick={() => void fetchLogs()}>
              <RotateCcw className="mr-2 h-4 w-4" aria-hidden="true" />
              Try again
            </Button>
          </Card>
        ) : isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="text-center">
              <div className="mx-auto h-8 w-8 animate-spin rounded-full border-b-2 border-primary-600" />
              <p className="mt-2 text-sm text-gray-500">Loading logs...</p>
            </div>
          </div>
        ) : logs.length === 0 ? (
          <Card className="flex min-h-72 flex-col items-center justify-center p-8 text-center">
            <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
              <ClipboardList className="h-6 w-6" aria-hidden="true" />
            </div>
            <h2 className="mt-4 text-lg font-semibold text-neutral-950">
              {hasActiveFilters ? 'No activity matches these filters' : 'No activity recorded yet'}
            </h2>
            <p className="mt-2 max-w-md text-sm text-neutral-500">
              {hasActiveFilters
                ? 'Clear the current filters to return to the complete activity history.'
                : 'Recorded changes for this client will appear here as payroll work is completed.'}
            </p>
            <Button className="mt-4" variant="outline" onClick={hasActiveFilters ? clearFilters : () => void fetchLogs()}>
              <RotateCcw className="mr-2 h-4 w-4" aria-hidden="true" />
              {hasActiveFilters ? 'Clear filters' : 'Refresh history'}
            </Button>
          </Card>
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
                    <p className="font-semibold text-neutral-950">{displayAction(log)}</p>
                    <p className="mt-1 text-sm text-neutral-500">
                      {log.user_name || 'System'} • {new Date(log.created_at).toLocaleString()}
                    </p>
                    <div className="mt-4 grid grid-cols-2 gap-3">
                      <MobileField label="Affected record" value={log.display_subject || log.subject_name || humanizeKey(log.record_type || 'General')} />
                      <MobileField label="Client" value={log.company_name || 'Organization-wide'} />
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
                    <TableHead>Activity</TableHead>
                    <TableHead>Affected record</TableHead>
                    <TableHead>Client</TableHead>
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
                      <TableCell className="font-medium text-neutral-900">{displayAction(log)}</TableCell>
                      <TableCell>{log.display_subject || log.subject_name || humanizeKey(log.record_type || 'General')}</TableCell>
                      <TableCell>{log.company_name || 'Organization-wide'}</TableCell>
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
                      <p className="text-lg font-semibold text-neutral-900">{displayAction(selectedLog)}</p>
                      <p className="mt-1 text-sm text-neutral-500">
                        {selectedLog.user_name || 'System'} • {new Date(selectedLog.created_at).toLocaleString()}
                      </p>
                    </div>

                    <DetailList
                      rows={[
                        ['Person', selectedLog.user_name || 'System'],
                        ['Affected record', selectedLog.display_subject || selectedLog.subject_name || humanizeKey(selectedLog.record_type || 'General')],
                        ['Client', selectedLog.company_name || 'Organization-wide'],
                      ]}
                    />

                    {changedFields.length > 0 ? (
                      <div>
                        <p className="text-sm font-medium text-neutral-900">What changed</p>
                        <div className="mt-3 space-y-3">
                          {changedFields.map((field) => (
                            <div key={field} className="rounded-2xl border border-neutral-200 bg-white p-4">
                              <p className="text-sm font-semibold text-neutral-900">{humanizeKey(field)}</p>
                              <div className="mt-3 grid gap-3 md:grid-cols-2">
                                {redactedFields.includes(field) ? (
                                  <p className="col-span-2 rounded-xl bg-amber-50 px-4 py-3 text-sm text-amber-800">
                                    Sensitive value updated. The original and new values are intentionally never stored in the audit log.
                                  </p>
                                ) : (
                                  <>
                                    <ValueCard label="Before" value={beforeValues[field]} />
                                    <ValueCard label="After" value={afterValues[field]} />
                                  </>
                                )}
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    ) : (
                      <p className="rounded-xl border border-dashed border-neutral-300 px-4 py-3 text-sm text-neutral-500">
                        Detailed before-and-after values were not captured for this historical activity.
                      </p>
                    )}

                    <details className="group rounded-2xl border border-neutral-200 bg-white">
                      <summary className="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-sm font-semibold text-neutral-700">
                        Advanced technical details
                        <ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" />
                      </summary>
                      <div className="space-y-3 border-t border-neutral-200 p-4">
                        <DetailList
                          rows={[
                            ['Technical action', selectedLog.action],
                            ['Actor email', selectedLog.actor_email || '—'],
                            ['Role', selectedLog.actor_role ? humanizeKey(selectedLog.actor_role) : '—'],
                            ['Record reference', `${selectedLog.record_type || 'general'}${selectedLog.record_id ? ` #${selectedLog.record_id}` : ''}`],
                            ['IP address', selectedLog.ip_address || '—'],
                            ['Request ID', selectedLog.request_id || '—'],
                          ]}
                        />
                        {detailEntries.map(([key, value]) => (
                          <div key={key} className="rounded-xl border border-neutral-200 px-4 py-3">
                            <p className="text-sm font-medium text-neutral-900">{humanizeKey(key)}</p>
                            <p className="mt-1 whitespace-pre-wrap text-sm text-neutral-600">{formatValue(value)}</p>
                          </div>
                        ))}
                      </div>
                    </details>
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
