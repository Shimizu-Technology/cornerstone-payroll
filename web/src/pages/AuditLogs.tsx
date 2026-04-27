import { useState, useEffect, useCallback, useMemo } from 'react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
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

  const fetchLogs = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await auditLogsApi.list({
        action_filter: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        limit: 200,
      });
      setLogs(response.data);
      setSelectedLogId((current) => response.data.find((log) => log.id === current)?.id || response.data[0]?.id || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load audit logs');
    } finally {
      setIsLoading(false);
    }
  }, [actionFilter, recordTypeFilter, userFilter, fromFilter, toFilter]);

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
    void fetchUsers();
  }, [fetchLogs, fetchUsers]);

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

      <div className="p-6 lg:p-8">
        <Card className="mb-4 p-4">
          <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
            <Input
              placeholder="Search actions"
              value={actionFilter}
              onChange={(e) => setActionFilter(e.target.value)}
            />
            <Input
              placeholder="Search records"
              value={recordTypeFilter}
              onChange={(e) => setRecordTypeFilter(e.target.value)}
            />
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm"
              value={userFilter}
              onChange={(e) => setUserFilter(e.target.value)}
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
              onChange={(e) => setFromFilter(e.target.value)}
            />
            <Input
              type="datetime-local"
              value={toFilter}
              onChange={(e) => setToFilter(e.target.value)}
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
                        ['Record', `${humanizeKey(selectedLog.record_type || 'General')}${selectedLog.record_id ? ` #${selectedLog.record_id}` : ''}`],
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
