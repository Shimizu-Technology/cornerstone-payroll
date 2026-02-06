import { useState, useEffect, useCallback } from 'react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
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

  const fetchLogs = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await auditLogsApi.list({
        action: actionFilter || undefined,
        record_type: recordTypeFilter || undefined,
        user_id: userFilter ? parseInt(userFilter, 10) : undefined,
        from: fromFilter || undefined,
        to: toFilter || undefined,
        limit: 200,
      });
      setLogs(response.data);
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
    fetchLogs();
    fetchUsers();
  }, [fetchLogs, fetchUsers]);

  return (
    <div>
      <Header
        title="Audit Logs"
        description="Track changes and actions across the system"
      />

      <div className="p-6 lg:p-8">
        <Card className="mb-4 p-4">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <Input
              placeholder="Filter by action (e.g., users#update)"
              value={actionFilter}
              onChange={(e) => setActionFilter(e.target.value)}
            />
            <Input
              placeholder="Filter by record type (e.g., api/v1/admin/users)"
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
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mt-3">
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

        {error && (
          <div className="mb-4 text-sm text-danger-600">{error}</div>
        )}

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="text-center">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600 mx-auto" />
              <p className="mt-2 text-sm text-gray-500">Loading logs...</p>
            </div>
          </div>
        ) : (
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
                  <TableRow key={log.id}>
                    <TableCell>{new Date(log.created_at).toLocaleString()}</TableCell>
                    <TableCell>{log.user_name || 'System'}</TableCell>
                    <TableCell>{log.action}</TableCell>
                    <TableCell>
                      {log.record_type || '—'}
                      {log.record_id ? ` #${log.record_id}` : ''}
                    </TableCell>
                    <TableCell>{log.ip_address || '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>
        )}
      </div>
    </div>
  );
}
