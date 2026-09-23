import { useState, useEffect, useCallback, useMemo, useRef, type ReactElement } from 'react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AuditEventDetails } from '@/components/audit/AuditEventDetails';
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
import { ArrowDownUp, ChevronDown, ClipboardList, Download, RotateCcw, TriangleAlert } from 'lucide-react';
import {
  displayAuditGroupAction,
  groupAuditEntries,
  humanizeAuditKey as humanizeKey,
} from '@/lib/audit-display';
import { formatGuamDateTime } from '@/lib/utils';

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
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
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
  const [activityView, setActivityView] = useState<'important' | 'documents' | 'all'>('important');
  const latestRequestId = useRef(0);

  const fetchLogs = useCallback(async () => {
    const requestId = ++latestRequestId.current;
    const append = page > 1;
    if (append) {
      setIsLoadingMore(true);
      setLoadMoreError(null);
    } else {
      setIsLoading(true);
      setError(null);
      setLoadMoreError(null);
    }
    try {
      const response = await auditLogsApi.list({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        event_category: activityView === 'documents' ? 'document_access' : undefined,
        exclude_event_category: activityView === 'important' ? 'document_access' : undefined,
        user_id: isAdmin && userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        page,
        per_page: 50,
        sort_direction: sortDirection,
        company_id: isAdmin ? undefined : activeCompanyId ?? undefined,
      });
      if (requestId !== latestRequestId.current) return;

      setLogs((current) => {
        if (!append) return response.data;

        const seen = new Set(current.map((log) => log.id));
        return [...current, ...response.data.filter((log) => !seen.has(log.id))];
      });
      setTotalPages(response.meta.total_pages || 1);
      setTotal(response.meta.total_count);
      if (!append) {
        setSelectedLogId((current) => response.data.find((log) => log.id === current)?.id || null);
      }
    } catch (err) {
      if (requestId !== latestRequestId.current) return;

      const message = err instanceof Error ? err.message : 'Failed to load audit logs';
      if (append) setLoadMoreError(message);
      else setError(message);
    } finally {
      if (requestId === latestRequestId.current) {
        setIsLoading(false);
        setIsLoadingMore(false);
      }
    }
  }, [actionFilter, activeCompanyId, activityView, isAdmin, recordTypeFilter, userFilter, fromFilter, toFilter, page, sortDirection]);

  const handleExport = async () => {
    setIsExporting(true);
    setExportError(null);
    try {
      const result = await auditLogsApi.exportCsv({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        event_category: activityView === 'documents' ? 'document_access' : undefined,
        exclude_event_category: activityView === 'important' ? 'document_access' : undefined,
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

  const hasActiveFilters = Boolean(
    actionFilter || recordTypeFilter || (isAdmin && userFilter) || fromFilter || toFilter || activityView !== 'important'
  );

  const clearFilters = (): void => {
    setActionFilter('');
    setRecordTypeFilter('');
    setUserFilter('');
    setFromFilter('');
    setToFilter('');
    setActivityView('important');
    setPage(1);
  };

  const groups = useMemo(() => groupAuditEntries(logs), [logs]);
  const selectedGroup = useMemo(
    () => groups.find((group) => group.primary.id === selectedLogId) || null,
    [groups, selectedLogId]
  );
  const selectedLog = selectedGroup?.primary || null;

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
            <div className="flex flex-col gap-2 sm:flex-row">
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
          <fieldset className="mb-4">
            <legend className="mb-2 text-xs font-bold uppercase tracking-[0.12em] text-neutral-500">Activity view</legend>
            <div className="grid grid-cols-1 gap-2 rounded-xl bg-neutral-100 p-1 sm:grid-cols-3">
              {([
                ['important', isAdmin ? 'Changes & sign-ins' : 'Changes'],
                ['documents', 'Document access'],
                ['all', 'All records'],
              ] as const).map(([value, label]) => (
                <button
                  className={`min-h-11 rounded-lg px-3 text-sm font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 ${activityView === value ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-600 hover:text-neutral-950'}`}
                  key={value}
                  type="button"
                  aria-pressed={activityView === value}
                  onClick={() => { setActivityView(value); setPage(1); }}
                >
                  {label}
                </button>
              ))}
            </div>
          </fieldset>
          <div className={`grid grid-cols-1 gap-4 ${isAdmin ? 'md:grid-cols-3' : 'md:grid-cols-2'}`}>
            <Input
              id="audit-action-filter"
              label="Action"
              placeholder="Search actions"
              value={actionFilter}
              onChange={(e) => {
                setActionFilter(e.target.value);
                setPage(1);
              }}
            />
            <Input
              id="audit-record-filter"
              label="Record"
              placeholder="Search records"
              value={recordTypeFilter}
              onChange={(e) => {
                setRecordTypeFilter(e.target.value);
                setPage(1);
              }}
            />
            {isAdmin && <label className="space-y-1.5 text-sm font-medium text-neutral-700">
              <span>Person</span>
              <select
                className="min-h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
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
            </label>}
          </div>
          <div className="mt-3 grid grid-cols-1 gap-3 md:grid-cols-2">
            <Input
              id="audit-from-filter"
              label="From"
              type="datetime-local"
              value={fromFilter}
              onChange={(e) => {
                setFromFilter(e.target.value);
                setPage(1);
              }}
            />
            <Input
              id="audit-to-filter"
              label="To"
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
              <div className="space-y-4 p-4 xl:hidden">
                {groups.map((group) => (
                  <MobileRecordCard key={group.key} tone={selectedLogId === group.primary.id ? 'primary' : 'default'}>
                    <button
                      className="min-h-11 w-full text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300"
                      type="button"
                      aria-expanded={selectedLogId === group.primary.id}
                      onClick={() => setSelectedLogId((current) => current === group.primary.id ? null : group.primary.id)}
                    >
                      <p className="font-semibold text-neutral-950">{displayAuditGroupAction(group)}</p>
                      <p className="mt-1 text-sm text-neutral-500">
                        {group.primary.user_name || 'System'} • {formatGuamDateTime(group.primary.created_at)}
                      </p>
                      <div className="mt-4 grid grid-cols-2 gap-4">
                        <MobileField label="Affected record" value={group.primary.display_subject || group.primary.subject_name || humanizeKey(group.primary.record_type || 'General')} />
                        <MobileField label="Client" value={group.primary.company_name || 'Organization-wide'} />
                      </div>
                      <span className="mt-4 flex items-center justify-between border-t border-neutral-100 pt-3 text-sm font-semibold text-primary-700">
                        {selectedLogId === group.primary.id ? 'Hide details' : 'View details'}
                        <ChevronDown
                          className={`h-4 w-4 transition-transform ${selectedLogId === group.primary.id ? 'rotate-180' : ''}`}
                          aria-hidden="true"
                        />
                      </span>
                    </button>
                    {selectedLogId === group.primary.id && (
                      <div className="mt-4 border-t border-primary-100 pt-4"><AuditEventDetails group={group} /></div>
                    )}
                  </MobileRecordCard>
                ))}
              </div>
              <div className="hidden xl:block">
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
                  {groups.map((group) => (
                    <TableRow
                      key={group.key}
                      className={`${selectedLogId === group.primary.id ? 'bg-primary-50/70' : ''} cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-300`}
                      aria-selected={selectedLogId === group.primary.id}
                      tabIndex={0}
                      onClick={() => setSelectedLogId(group.primary.id)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter' || event.key === ' ') {
                          event.preventDefault();
                          setSelectedLogId(group.primary.id);
                        }
                      }}
                    >
                      <TableCell>{formatGuamDateTime(group.primary.created_at)}</TableCell>
                      <TableCell>{group.primary.user_name || 'System'}</TableCell>
                      <TableCell className="font-medium text-neutral-900">{displayAuditGroupAction(group)}</TableCell>
                      <TableCell>{group.primary.display_subject || group.primary.subject_name || humanizeKey(group.primary.record_type || 'General')}</TableCell>
                      <TableCell>{group.primary.company_name || 'Organization-wide'}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
                </Table>
              </div>
              {(page < totalPages || loadMoreError) && (
                <div className="border-t border-neutral-200 px-4 py-4 text-center">
                  {loadMoreError && <p className="mb-3 text-sm text-danger-700" role="alert">{loadMoreError}</p>}
                  <Button
                    className="min-h-11"
                    variant="outline"
                    onClick={() => loadMoreError ? void fetchLogs() : setPage((value) => Math.min(totalPages, value + 1))}
                    disabled={isLoadingMore}
                  >
                    <ChevronDown className="mr-2 h-4 w-4" aria-hidden="true" />
                    {isLoadingMore ? 'Loading more activity…' : loadMoreError ? 'Try loading more activity again' : 'Load more activity'}
                  </Button>
                </div>
              )}
            </Card>

            <Card className="hidden xl:block">
              <CardHeader>
                <CardTitle>{selectedLog ? 'Selected Activity' : 'Activity Details'}</CardTitle>
              </CardHeader>
              <CardContent className="space-y-5">
                {selectedGroup && selectedLog ? (
                  <>
                    <div className="rounded-2xl border border-neutral-200 bg-neutral-50 px-4 py-4">
                      <p className="text-lg font-semibold text-neutral-900">{displayAuditGroupAction(selectedGroup)}</p>
                      <p className="mt-1 text-sm text-neutral-500">
                        {selectedLog.user_name || 'System'} • {formatGuamDateTime(selectedLog.created_at)}
                      </p>
                    </div>

                    <DetailList
                      rows={[
                        ['Person', selectedLog.user_name || 'System'],
                        ['Affected record', selectedLog.display_subject || selectedLog.subject_name || humanizeKey(selectedLog.record_type || 'General')],
                        ['Client', selectedLog.company_name || 'Organization-wide'],
                      ]}
                    />

                    <AuditEventDetails group={selectedGroup} />
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
