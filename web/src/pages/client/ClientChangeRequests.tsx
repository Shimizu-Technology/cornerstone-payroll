import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router';
import { ChangeComparison } from '@/components/employees/ChangeComparison';
import { ContactChangeActivity } from '@/components/employees/ContactChangeActivity';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { MobileRecordCard } from '@/components/ui/mobile-record';
import { LoadMoreFooter } from '@/components/ui/load-more';
import { appendUniqueById, hasMorePages } from '@/lib/paged-list';
import { ApiError, clientEmployeeChangeRequestsApi } from '@/services/api';
import type { BoundedListMeta, EmployeeChangeRequest } from '@/services/api';

export function ClientChangeRequests() {
  const location = useLocation();
  const navigate = useNavigate();
  const routeState = location.state as { portalNotice?: string; selectedRequestId?: number | null } | null;
  const [requests, setRequests] = useState<EmployeeChangeRequest[]>([]);
  const [requestsMeta, setRequestsMeta] = useState<BoundedListMeta | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
  // Bumped on every fresh load so a slow "load more" for old filters is dropped.
  const listGeneration = useRef(0);
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('');
  const [selected, setSelected] = useState<EmployeeChangeRequest | null>(null);
  const [notice, setNotice] = useState<string | null>(routeState?.portalNotice || null);
  const query = new URLSearchParams(location.search);
  const requestedSelection = Number(query.get('request_id')) || routeState?.selectedRequestId || null;
  const pendingSelection = useRef<number | null>(null);
  const showingContactChanges = query.get('view') === 'contact';
  const [profileRequestsEnabled, setProfileRequestsEnabled] = useState(false);
  const [decision, setDecision] = useState<'approve' | 'reject' | null>(null);
  const [reviewNotes, setReviewNotes] = useState('');
  const [deciding, setDeciding] = useState(false);
  const detailGeneration = useRef(0);
  const detailsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (requestedSelection !== null) pendingSelection.current = requestedSelection;
  }, [requestedSelection]);

  const load = useCallback(async () => {
    const generation = ++listGeneration.current;
    const details = ++detailGeneration.current;
    try {
      setLoading(true);
      setError(null);
      const response = await clientEmployeeChangeRequestsApi.list({
        search: search.trim() || undefined,
        status: status || undefined,
      });
      if (generation !== listGeneration.current) return;
      setProfileRequestsEnabled(response.meta?.profile_requests_enabled === true);
      setRequests(response.data);
      setRequestsMeta(response.meta ?? null);
      setLoadMoreError(null);
      setSelected(null);
      if (showingContactChanges && response.meta?.profile_requests_enabled) return;

      const fallbackId = response.data[0]?.id;
      const nextSelection = pendingSelection.current ?? fallbackId;
      pendingSelection.current = null;
      if (!nextSelection) return;

      let detail = await getRequestIfVisible(nextSelection);
      if (details !== detailGeneration.current) return;
      if (!detail && fallbackId && fallbackId !== nextSelection) {
        detail = await getRequestIfVisible(fallbackId);
      }
      if (details === detailGeneration.current) setSelected(detail?.data ?? null);
    } catch (err) {
      if (generation === listGeneration.current) {
        setError(err instanceof Error ? err.message : 'Failed to load change requests');
      }
    } finally {
      if (generation === listGeneration.current) setLoading(false);
    }
  }, [search, setError, showingContactChanges, status]);

  useEffect(() => {
    void load();
    return () => { listGeneration.current += 1; detailGeneration.current += 1; };
  }, [load, requestedSelection]);

  const loadMore = async () => {
    if (!requestsMeta) return;
    const generation = listGeneration.current;
    try {
      setLoadingMore(true);
      setLoadMoreError(null);
      const response = await clientEmployeeChangeRequestsApi.list({
        search: search.trim() || undefined,
        status: status || undefined,
        page: requestsMeta.current_page + 1,
      });
      if (generation !== listGeneration.current) return;
      setRequests((current) => appendUniqueById(current, response.data));
      setRequestsMeta(response.meta ?? null);
    } catch (err) {
      if (generation !== listGeneration.current) return;
      setLoadMoreError(err instanceof Error ? err.message : 'Failed to load more change requests');
    } finally {
      setLoadingMore(false);
    }
  };

  useEffect(() => {
    if (!routeState) return;
    navigate({ pathname: location.pathname, search: location.search }, { replace: true, state: null });
  }, [location.pathname, location.search, navigate, routeState]);

  const loadRequest = async (id: number) => {
    const generation = ++detailGeneration.current;
    setSelected(null);
    setError(null);
    try {
      const response = await clientEmployeeChangeRequestsApi.get(id);
      if (generation !== detailGeneration.current) return;
      setSelected(response.data);
      if (window.innerWidth < 1024) {
        requestAnimationFrame(() => detailsRef.current?.scrollIntoView({ block: 'start' }));
      }
    } catch (err) {
      if (generation === detailGeneration.current) {
        setError(err instanceof Error ? err.message : 'Could not load this request.');
      }
    }
  };

  const submitDecision = async () => {
    if (!selected || !decision) return;
    setDeciding(true);
    setError(null);
    setNotice(null);
    try {
      const { data } = await clientEmployeeChangeRequestsApi.decide(selected.id, decision, reviewNotes.trim() || undefined);
      setSelected(data);
      if (status && data.status !== status) {
        setRequests((rows) => rows.filter((row) => row.id !== data.id));
        setRequestsMeta((meta) => meta && { ...meta, total_count: Math.max(0, meta.total_count - 1) });
      } else {
        setRequests((rows) => rows.map((row) => row.id === data.id ? data : row));
      }
      setNotice(decision === 'approve' ? 'Address approved and updated on the employee record.' : 'Address request rejected.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not review this request.');
    } finally {
      setDeciding(false);
      setDecision(null);
    }
  };

  return (
    <div>
      <Header title="Change requests"
        description={profileRequestsEnabled ? 'Review address requests and see applied contact changes.' : 'Track payroll-sensitive updates submitted for payroll team approval.'} />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {notice && (
          <div role="status" className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">
            <span>{notice}</span>
            <Button variant="ghost" size="sm" onClick={() => setNotice(null)}>Dismiss</Button>
          </div>
        )}
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}

        {profileRequestsEnabled && (
          <nav aria-label="Employee changes" className="flex flex-wrap gap-3">
            <Link className={tabClass(!showingContactChanges)} to="/change-requests" aria-current={!showingContactChanges ? 'page' : undefined}>Requests</Link>
            <Link className={tabClass(showingContactChanges)} to="/change-requests?view=contact" aria-current={showingContactChanges ? 'page' : undefined}>Contact changes</Link>
          </nav>
        )}
        {showingContactChanges && profileRequestsEnabled ? <ContactChangeActivity /> : <>
        <div className="flex flex-col gap-4 md:flex-row">
          <Input aria-label="Search employees" value={search} onChange={(e) => { pendingSelection.current = null; setSearch(e.target.value); }} placeholder="Search employees..." className="max-w-md" />
          <Select aria-label="Request status" value={status} onChange={(e) => { pendingSelection.current = null; setStatus(e.target.value); }} className="w-full md:w-44">
            <option value="">All Statuses</option>
            <option value="pending">Pending</option>
            <option value="approved">Approved</option>
            <option value="rejected">Rejected</option>
            <option value="cancelled">Cancelled</option>
          </Select>
        </div>

        <div className="grid min-w-0 gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
          <Card className="min-w-0">
            <CardContent className="p-0">
              {loading ? (
                <div className="py-12 text-center text-sm text-gray-500">Loading change requests...</div>
              ) : requests.length === 0 ? (
                search.trim() || status ? (
                  <div className="py-12 text-center text-sm text-gray-600">No change requests match these filters.</div>
                ) : (
                  <div className="mx-auto max-w-xl space-y-2 px-4 py-10 text-sm text-neutral-700">
                    <p className="font-semibold text-neutral-900">No change requests yet.</p>
                    <p>
                      When you add an employee, or change an employee&apos;s pay, tax withholding, SSN or retirement details, Cornerstone reviews the change before payroll uses it. Each request appears here with its status.
                      {profileRequestsEnabled && ' Address changes employees ask for in the employee app appear here too.'}
                    </p>
                    <p>
                      To ask for a change, open <Link className="font-semibold text-primary-800 underline underline-offset-2" to="/employees">Employees</Link>, choose the employee and select <strong>Edit employee</strong>.
                    </p>
                  </div>
                )
              ) : (
                <>
                <div className="space-y-3 p-3 lg:hidden">
                  {requests.map((request) => (
                    <MobileRecordCard key={request.id}>
                      <div className="flex flex-wrap items-start justify-between gap-2">
                        <p className="min-w-0 font-semibold text-neutral-950">{request.employee_name}</p>
                        <StatusBadge status={request.status} />
                      </div>
                      <p className="mt-2 text-sm text-neutral-600">{requestLabel(request)} · {new Date(request.created_at).toLocaleDateString()}</p>
                      <p className="mt-1 text-xs text-neutral-500">Requested by {request.requested_by_name || '—'}</p>
                      <Button className="mt-4 w-full" variant="outline" onClick={() => void loadRequest(request.id)}>View request</Button>
                    </MobileRecordCard>
                  ))}
                </div>
                <div className="hidden lg:block">
                <Table stickyHeader>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Employee</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead>Requested by</TableHead>
                      <TableHead>Submitted</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody striped>
                    {requests.map((request) => (
                      <TableRow key={request.id}>
                        <TableCell className="font-medium text-gray-900"><button type="button" className="inline-flex min-h-11 items-center text-left text-primary-700 underline-offset-2 hover:underline focus-visible:underline" onClick={() => void loadRequest(request.id)}>{request.employee_name}</button></TableCell>
                        <TableCell><StatusBadge status={request.status} /></TableCell>
                        <TableCell>{requestLabel(request)}</TableCell>
                        <TableCell>{request.requested_by_name || '—'}</TableCell>
                        <TableCell>{new Date(request.created_at).toLocaleString()}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                </div>
                <LoadMoreFooter
                  shown={requests.length}
                  total={requestsMeta?.total_count ?? requests.length}
                  noun="change requests"
                  hasMore={hasMorePages(requestsMeta)}
                  loading={loadingMore}
                  error={loadMoreError}
                  onLoadMore={() => void loadMore()}
                />
                </>
              )}
            </CardContent>
          </Card>

          <Card ref={detailsRef} className="min-w-0 scroll-mt-4">
            <CardHeader>
              <CardTitle>{selected ? `Request #${selected.id}` : 'Request details'}</CardTitle>
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
                  <DetailBlock title="Request type" value={requestLabel(selected)} />
                  <DetailBlock title="Request notes" value={selected.request_notes} />
                  <DetailBlock title="Review notes" value={selected.review_notes} />
                  <ChangeComparison
                    before={selected.original_values}
                    after={selected.proposed_changes}
                    requested={selected.status !== 'approved'}
                    current={selected.profile_address && selected.status === 'pending'}
                  />
                  {selected.can_review && (
                    <div className="flex flex-wrap gap-2">
                      <Button onClick={() => { setReviewNotes(''); setDecision('approve'); }}>Approve</Button>
                      <Button variant="outline" onClick={() => { setReviewNotes(''); setDecision('reject'); }}>Reject</Button>
                    </div>
                  )}
                  {profileRequestsEnabled && selected.profile_address && selected.status === 'pending' && selected.can_review === false && (
                    <p className="text-sm text-neutral-600">Another administrator or Cornerstone must review this request.</p>
                  )}
                </div>
              ) : (
                <div className="text-sm text-gray-500">Select a change request to view details.</div>
              )}
            </CardContent>
          </Card>
        </div>
        </>}
      </div>
      <Dialog open={decision !== null} onOpenChange={(open) => { if (!open && !deciding) setDecision(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{decision === 'approve' ? 'Approve address change?' : 'Reject address request?'}</DialogTitle>
            <DialogDescription>
              {decision === 'approve' ? 'The requested address will be saved on the employee record.' : 'The current address will stay on file.'}
            </DialogDescription>
          </DialogHeader>
          <label className="space-y-1 text-sm font-medium">
            <span>
              {selected?.note_visible_to_employee ? "Note to the employee (they'll see this)" : 'Review note'}
              <span aria-hidden="true" className="font-normal text-gray-600"> (optional)</span>
            </span>
            <Input value={reviewNotes} disabled={deciding} onChange={(event) => setReviewNotes(event.target.value)} />
          </label>
          <DialogFooter>
            <Button variant="outline" disabled={deciding} onClick={() => setDecision(null)}>Cancel</Button>
            <Button variant={decision === 'reject' ? 'danger' : 'default'} disabled={deciding} onClick={() => void submitDecision()}>
              {deciding ? 'Saving…' : decision === 'approve' ? 'Approve address' : 'Reject request'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function StatusBadge({ status }: { status: EmployeeChangeRequest['status'] }) {
  const variant = status === 'approved' ? 'success' : status === 'rejected' ? 'danger' : status === 'pending' ? 'warning' : 'default';
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

function requestLabel(request: EmployeeChangeRequest) {
  if (request.profile_address) return 'Address change';
  return request.request_kind === 'create' ? 'New worker' : 'Employee update';
}

function tabClass(active: boolean) {
  return `rounded-md px-3 py-2 text-sm font-medium focus-visible:outline-primary-600 ${active ? 'bg-primary-100 text-primary-800' : 'text-neutral-700 hover:bg-neutral-100'}`;
}

async function getRequestIfVisible(id: number) {
  try {
    return await clientEmployeeChangeRequestsApi.get(id);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}
