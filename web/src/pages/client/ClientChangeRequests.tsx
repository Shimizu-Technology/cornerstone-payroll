import { useCallback, useEffect, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { clientEmployeeChangeRequestsApi } from '@/services/api';
import type { EmployeeChangeRequest } from '@/services/api';

export function ClientChangeRequests() {
  const [requests, setRequests] = useState<EmployeeChangeRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('');
  const [selected, setSelected] = useState<EmployeeChangeRequest | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await clientEmployeeChangeRequestsApi.list({
        search: search || undefined,
        status: status || undefined,
      });
      setRequests(response.data);
      setSelected((current) => response.data.find((request) => request.id === current?.id) || response.data[0] || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load change requests');
    } finally {
      setLoading(false);
    }
  }, [search, status]);

  useEffect(() => {
    void load();
  }, [load]);

  const loadRequest = async (id: number) => {
    const response = await clientEmployeeChangeRequestsApi.get(id);
    setSelected(response.data);
  };

  return (
    <div>
      <Header title="Change Requests" description="Track payroll-sensitive updates submitted for payroll team approval." />

      <div className="p-6 lg:p-8 space-y-6">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        <div className="flex flex-col gap-4 md:flex-row">
          <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search employees..." className="max-w-md" />
          <Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-44">
            <option value="">All Statuses</option>
            <option value="pending">Pending</option>
            <option value="approved">Approved</option>
            <option value="rejected">Rejected</option>
          </Select>
        </div>

        <div className="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
          <Card>
            <CardContent className="p-0">
              {loading ? (
                <div className="py-12 text-center text-sm text-gray-500">Loading change requests...</div>
              ) : requests.length === 0 ? (
                <div className="py-12 text-center text-sm text-gray-500">No change requests found.</div>
              ) : (
                <Table stickyHeader>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Employee</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Requested By</TableHead>
                      <TableHead>Submitted</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody striped>
                    {requests.map((request) => (
                      <TableRow key={request.id} className="cursor-pointer hover:bg-primary-50/60" onClick={() => void loadRequest(request.id)}>
                        <TableCell className="font-medium text-gray-900">{request.employee_name}</TableCell>
                        <TableCell><StatusBadge status={request.status} /></TableCell>
                        <TableCell>{request.requested_by_name || '—'}</TableCell>
                        <TableCell>{new Date(request.created_at).toLocaleString()}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{selected ? `Request #${selected.id}` : 'Request Details'}</CardTitle>
            </CardHeader>
            <CardContent>
              {selected ? (
                <div className="space-y-4">
                  <div className="flex items-center gap-3">
                    <StatusBadge status={selected.status} />
                    <span className="text-sm text-gray-500">
                      Submitted {new Date(selected.created_at).toLocaleString()}
                    </span>
                  </div>
                  <div className="rounded-xl border border-gray-200 bg-gray-50 p-4">
                    <p className="text-sm font-medium text-gray-900">Employee</p>
                    <p className="text-sm text-gray-600">{selected.employee_name}</p>
                  </div>
                  <DetailBlock title="Request Notes" value={selected.request_notes} />
                  <DetailBlock title="Review Notes" value={selected.review_notes} />
                  <JsonBlock title="Original Values" value={selected.original_values} />
                  <JsonBlock title="Proposed Changes" value={selected.proposed_changes} />
                </div>
              ) : (
                <div className="text-sm text-gray-500">Select a change request to view details.</div>
              )}
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: EmployeeChangeRequest['status'] }) {
  const variant = status === 'approved' ? 'success' : status === 'rejected' ? 'danger' : 'warning';
  return <Badge variant={variant}>{status.charAt(0).toUpperCase() + status.slice(1)}</Badge>;
}

function DetailBlock({ title, value }: { title: string; value?: string | null }) {
  return (
    <div>
      <p className="text-sm font-medium text-gray-900">{title}</p>
      <p className="mt-1 text-sm text-gray-600">{value || '—'}</p>
    </div>
  );
}

function JsonBlock({ title, value }: { title: string; value?: Record<string, unknown> }) {
  return (
    <div>
      <p className="text-sm font-medium text-gray-900">{title}</p>
      <pre className="mt-2 overflow-auto rounded-xl bg-gray-950/95 p-3 text-xs text-gray-100">
        {JSON.stringify(value || {}, null, 2)}
      </pre>
    </div>
  );
}
