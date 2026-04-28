import { useCallback, useEffect, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { adminEmployeeChangeRequestsApi } from '@/services/api';
import type { EmployeeChangeRequest } from '@/services/api';

export function AdminEmployeeChangeRequestsPage() {
  const [requests, setRequests] = useState<EmployeeChangeRequest[]>([]);
  const [selected, setSelected] = useState<EmployeeChangeRequest | null>(null);
  const [status, setStatus] = useState('pending');
  const [reviewNotes, setReviewNotes] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await adminEmployeeChangeRequestsApi.list({ status: status || undefined });
      setRequests(response.data);
      if (response.data[0]) {
        await selectRequest(response.data[0].id);
      } else {
        setSelected(null);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load client change requests');
    } finally {
      setLoading(false);
    }
  }, [status]);

  useEffect(() => {
    void load();
  }, [load]);

  const selectRequest = async (id: number) => {
    const response = await adminEmployeeChangeRequestsApi.get(id);
    setSelected(response.data);
    setReviewNotes(response.data.review_notes || '');
  };

  const updateRequest = async (action: 'approve' | 'reject') => {
    if (!selected) return;
    try {
      setSaving(true);
      setError(null);
      if (action === 'approve') {
        await adminEmployeeChangeRequestsApi.approve(selected.id, reviewNotes);
      } else {
        await adminEmployeeChangeRequestsApi.reject(selected.id, reviewNotes);
      }
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : `Failed to ${action} request`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div>
      <Header title="Client Change Requests" description="Review and approve payroll-sensitive client-submitted changes." />

      <div className="p-6 lg:p-8 space-y-6">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        <div className="max-w-xs">
          <Select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="pending">Pending</option>
            <option value="approved">Approved</option>
            <option value="rejected">Rejected</option>
            <option value="">All Statuses</option>
          </Select>
        </div>

        <div className="grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
          <Card>
            <CardContent className="p-0">
              {loading ? (
                <div className="py-12 text-center text-sm text-gray-500">Loading requests...</div>
              ) : requests.length === 0 ? (
                <div className="py-12 text-center text-sm text-gray-500">No requests found.</div>
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
                      <TableRow key={request.id} className="cursor-pointer hover:bg-primary-50/60" onClick={() => void selectRequest(request.id)}>
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
            <CardContent className="space-y-4">
              {selected ? (
                <>
                  <div className="flex items-center gap-3">
                    <StatusBadge status={selected.status} />
                    <span className="text-sm text-gray-500">Submitted by {selected.requested_by_name || 'Unknown'}</span>
                  </div>
                  <JsonBlock title="Original Values" value={selected.original_values} />
                  <JsonBlock title="Proposed Changes" value={selected.proposed_changes} />
                  <div>
                    <p className="mb-1 text-sm font-medium text-gray-900">Review Notes</p>
                    <Textarea value={reviewNotes} onChange={(e) => setReviewNotes(e.target.value)} rows={4} />
                  </div>
                  {selected.status === 'pending' ? (
                    <div className="flex gap-3">
                      <Button disabled={saving} onClick={() => void updateRequest('approve')}>
                        {saving ? 'Saving...' : 'Approve'}
                      </Button>
                      <Button variant="outline" disabled={saving} onClick={() => void updateRequest('reject')}>
                        Reject
                      </Button>
                    </div>
                  ) : null}
                </>
              ) : (
                <div className="text-sm text-gray-500">Select a request to view details.</div>
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
