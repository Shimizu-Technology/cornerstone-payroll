import { useCallback, useEffect, useRef, useState } from 'react';
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
  const detailRef = useRef<HTMLDivElement>(null);
  const currentStatusRef = useRef(status);
  const listRequestIdRef = useRef(0);
  const detailRequestIdRef = useRef(0);

  const invalidateRequests = useCallback(() => {
    ++listRequestIdRef.current;
    ++detailRequestIdRef.current;
  }, []);

  const selectRequest = useCallback(async (id: number) => {
    const requestId = ++detailRequestIdRef.current;
    setSelected(null);
    setReviewNotes('');
    setError(null);
    try {
      const response = await adminEmployeeChangeRequestsApi.get(id);
      if (detailRequestIdRef.current !== requestId) return;
      setSelected(response.data);
      setReviewNotes(response.data.review_notes || '');
    } catch (err) {
      if (detailRequestIdRef.current === requestId) {
        setError(err instanceof Error ? err.message : 'Failed to load request details');
      }
    }
  }, []);

  const load = useCallback(async () => {
    const requestId = ++listRequestIdRef.current;
    const requestedStatus = currentStatusRef.current;
    const isCurrentRequest = () => listRequestIdRef.current === requestId && currentStatusRef.current === requestedStatus;
    ++detailRequestIdRef.current;
    try {
      setLoading(true);
      setError(null);
      setSelected(null);
      setReviewNotes('');
      const response = await adminEmployeeChangeRequestsApi.list({ status: requestedStatus || undefined });
      if (!isCurrentRequest()) return;
      setRequests(response.data);
      if (response.data[0]) {
        await selectRequest(response.data[0].id);
      }
    } catch (err) {
      if (isCurrentRequest()) {
        setError(err instanceof Error ? err.message : 'Failed to load client change requests');
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [selectRequest]);

  useEffect(() => {
    void load();
    return invalidateRequests;
  }, [status, load, invalidateRequests]);

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

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        <div className="max-w-xs">
          <Select value={status} onChange={(e) => {
            currentStatusRef.current = e.target.value;
            invalidateRequests();
            setSelected(null);
            setReviewNotes('');
            setStatus(e.target.value);
          }}>
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
                <>
                <div className="space-y-3 p-4 sm:hidden">
                  {requests.map((request) => (
                    <button
                      key={request.id}
                      type="button"
                      aria-pressed={selected?.id === request.id}
                      onClick={() => {
                        void selectRequest(request.id).then(() => {
                          detailRef.current?.focus({ preventScroll: true });
                          detailRef.current?.scrollIntoView?.({ block: 'start' });
                        });
                      }}
                      className={`w-full rounded-xl border p-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 ${selected?.id === request.id ? 'border-primary-300 bg-primary-50' : 'border-neutral-200 bg-white'}`}
                    >
                      <span className="flex items-start justify-between gap-2">
                        <span className="min-w-0 break-words font-semibold text-neutral-950">{request.employee_name}</span>
                        <StatusBadge status={request.status} />
                      </span>
                      <span className="mt-3 block text-sm text-neutral-600">{request.request_kind === 'create' ? 'New worker' : 'Update'} · {request.requested_by_name || 'Unknown requester'}</span>
                      <span className="mt-1 block text-xs text-neutral-500">Submitted {new Date(request.created_at).toLocaleString()}</span>
                      <span className="mt-3 block text-sm font-semibold text-primary-700">Review request</span>
                    </button>
                  ))}
                </div>
                <div className="hidden sm:block">
                <Table stickyHeader>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Employee</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead>Requested By</TableHead>
                      <TableHead>Submitted</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody striped>
                    {requests.map((request) => (
                      <TableRow key={request.id} className="cursor-pointer hover:bg-primary-50/60" tabIndex={0} onClick={() => void selectRequest(request.id)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); void selectRequest(request.id); } }}>
                        <TableCell className="font-medium text-gray-900">{request.employee_name}</TableCell>
                        <TableCell><StatusBadge status={request.status} /></TableCell>
                        <TableCell>{request.request_kind === 'create' ? 'New worker' : 'Update'}</TableCell>
                        <TableCell>{request.requested_by_name || '—'}</TableCell>
                        <TableCell>{new Date(request.created_at).toLocaleString()}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                </div>
                </>
              )}
            </CardContent>
          </Card>

          <Card ref={detailRef} tabIndex={-1} className="scroll-mt-4 outline-none">
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
                  <div className="rounded-xl border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-700">
                    {selected.request_kind === 'create'
                      ? 'Approving this request activates the new worker after applying the reviewed payroll details.'
                      : 'Approving this request applies the reviewed payroll-sensitive changes.'}
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
