import { formatGuamDateTime } from '@/lib/utils';
import { useSearchParams } from 'react-router';
import { InboxReturnLink } from '@/components/client-portal/InboxReturnLink';
import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteCompany } from '@/lib/company-write-access';
import { ChangeComparison } from '@/components/employees/ChangeComparison';
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
  const [searchParams] = useSearchParams();
  const deepRequestId = Number(searchParams.get('request_id')) || null;
  const pendingDeepSelection = useRef(deepRequestId);
  const { activeCompany, activeCompanyId } = useCompany();
  const [scopeCompanyId] = useState(activeCompanyId);
  const canWrite = scopeCompanyId === activeCompanyId && canWriteCompany(activeCompany, 'manage_client_configuration');
  const [requests, setRequests] = useState<EmployeeChangeRequest[]>([]);
  const [selected, setSelected] = useState<EmployeeChangeRequest | null>(null);
  const canReview = canWrite && selected?.can_review !== false;
  const [status, setStatus] = useState(() => deepRequestId ? '' : 'pending');
  const [reviewNotes, setReviewNotes] = useState('');
  const [effectiveOn, setEffectiveOn] = useState('');
  const [loading, setLoading] = useState(true);
  const [savingAction, setSavingAction] = useState<'approve' | 'reject' | null>(null);
  const saving = savingAction !== null;
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const detailRef = useRef<HTMLDivElement>(null);
  const currentStatusRef = useRef(status);
  const listRequestIdRef = useRef(0);
  const detailRequestIdRef = useRef(0);

  useEffect(() => {
    pendingDeepSelection.current = deepRequestId;
    if (deepRequestId) { currentStatusRef.current = ''; setStatus(''); }
  }, [deepRequestId]);

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
      setEffectiveOn(response.data.proposed_compensation_effective_on || '');
      setReviewNotes(response.data.review_notes || '');
    } catch (err) {
      if (detailRequestIdRef.current === requestId) {
        setError(err instanceof Error ? err.message : 'Failed to load request details');
      }
    }
  }, [setError]);

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
      const selectedId = pendingDeepSelection.current || response.data[0]?.id;
      pendingDeepSelection.current = null;
      if (selectedId) {
        await selectRequest(selectedId);
      }
    } catch (err) {
      if (isCurrentRequest()) {
        setError(err instanceof Error ? err.message : 'Failed to load client change requests');
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [selectRequest, setError]);

  useEffect(() => {
    void load();
    return invalidateRequests;
  }, [status, load, invalidateRequests, deepRequestId]);

  const updateRequest = async (action: 'approve' | 'reject') => {
    if (!selected || !canReview) return;
    try {
      setSavingAction(action);
      setError(null);
      if (action === 'approve') {
        await adminEmployeeChangeRequestsApi.approve(selected.id, reviewNotes, effectiveOn || undefined);
      } else {
        await adminEmployeeChangeRequestsApi.reject(selected.id, reviewNotes);
      }
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : `Failed to ${action} request`);
    } finally {
      setSavingAction(null);
    }
  };

  return (
    <div>
      <Header title="Client Change Requests" description="Review and approve payroll-sensitive client-submitted changes." />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        <InboxReturnLink />
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}

        <div className="max-w-xs">
          <Select value={status} onChange={(e) => {
            pendingDeepSelection.current = null;
            currentStatusRef.current = e.target.value;
            invalidateRequests();
            setSelected(null);
            setReviewNotes('');
            setStatus(e.target.value);
          }}>
            <option value="pending">Pending</option>
            <option value="approved">Approved</option>
            <option value="rejected">Rejected</option>
            <option value="cancelled">Cancelled</option>
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
                      <span className="mt-3 block text-sm text-neutral-600">{requestLabel(request)} · {request.requested_by_name || 'Unknown requester'}</span>
                      <span className="mt-1 block text-xs text-neutral-500">Submitted {formatGuamDateTime(request.created_at)}</span>
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
                        <TableCell>{requestLabel(request)}</TableCell>
                        <TableCell>{request.requested_by_name || '—'}</TableCell>
                        <TableCell>{formatGuamDateTime(request.created_at)}</TableCell>
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
                  {selected.status === 'pending' && <div className="rounded-xl border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-700">
                    {selected.request_kind === 'create'
                      ? 'Approving this request activates the new worker after applying the reviewed payroll details.'
                      : selected.profile_address
                        ? 'Approving this request updates the employee’s address and adds it to Changes to confirm.'
                        : 'Approving this request applies the reviewed payroll-sensitive changes.'}
                  </div>}
                  <ChangeComparison
                    before={selected.original_values}
                    after={selected.proposed_changes}
                    requested={selected.status !== 'approved'}
                  />
                  <div>
                    <label htmlFor="staff-review-note" className="mb-1 block text-sm font-medium text-gray-900">
                      {selected.note_visible_to_employee ? "Note to the employee (they'll see this)" : 'Review note'}
                      {selected.status === 'pending' && <span aria-hidden="true" className="font-normal text-gray-600"> (optional)</span>}
                    </label>
                    <Textarea id="staff-review-note" value={reviewNotes} onChange={(e) => setReviewNotes(e.target.value)} rows={4} readOnly={selected.status !== 'pending'} />
                  </div>
                  {selected.status === 'pending' && selected.proposed_compensation_effective_on && (
                    <label className="block text-sm font-medium text-neutral-800">
                      Pay change effective date
                      <input type="date" required value={effectiveOn} onChange={(event) => setEffectiveOn(event.target.value)}
                        className="mt-1 block rounded-md border border-neutral-300 bg-white px-3 py-2" />
                    </label>
                  )}
                  {selected.status === 'pending' ? (
                    <div className="flex gap-3">
                      <Button disabled={saving || !canReview || Boolean(selected.proposed_compensation_effective_on && !effectiveOn)} onClick={() => void updateRequest('approve')}>
                        {savingAction === 'approve' ? 'Approving…' : 'Approve'}
                      </Button>
                      <Button variant="outline" disabled={saving || !canReview} onClick={() => void updateRequest('reject')}>
                        {savingAction === 'reject' ? 'Rejecting…' : 'Reject'}
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
  const variant = status === 'approved' ? 'success' : status === 'rejected' ? 'danger' : status === 'pending' ? 'warning' : 'default';
  return <Badge variant={variant}>{status.charAt(0).toUpperCase() + status.slice(1)}</Badge>;
}

function requestLabel(request: EmployeeChangeRequest) {
  if (request.profile_address) return 'Address change';
  return request.request_kind === 'create' ? 'New worker' : 'Update';
}
