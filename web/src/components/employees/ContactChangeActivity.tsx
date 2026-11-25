import { useEffect, useState } from 'react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { ChangeComparison } from '@/components/employees/ChangeComparison';
import { EmployeeAppTurnOnStep } from '@/components/employee-app/EmployeeAppTurnOnStep';
import { apiErrorCode } from '@/lib/api-error-code';
import { clientEmployeeChangeRequestsApi, staffEmployeeContactChangesApi } from '@/services/api';
import type { BoundedListMeta, ContactActivityFilters, EmployeeContactActivity } from '@/services/api';

type ActivityMeta = BoundedListMeta & { through_id?: number | null };

export function ContactChangeActivity({ staffCompanyId, companyName }: { staffCompanyId?: number; companyName?: string }) {
  const [rows, setRows] = useState<EmployeeContactActivity[]>([]);
  const [meta, setMeta] = useState<ActivityMeta>();
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState<'unconfirmed' | 'confirmed'>('unconfirmed');
  const [kind, setKind] = useState<ContactActivityFilters['kind']>();
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');
  // The API answers feature_off while contact and address updates are off.
  const [featureOff, setFeatureOff] = useState(false);
  const [notice, setNotice] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [reload, setReload] = useState(0);
  const [confirmAllOpen, setConfirmAllOpen] = useState(false);

  const searchFilter = search.trim() || undefined;

  useEffect(() => {
    let current = true;
    setLoading(true);
    setError('');
    const request = staffCompanyId
      ? staffEmployeeContactChangesApi.list(staffCompanyId, { status, kind, search: searchFilter }, page)
      : clientEmployeeChangeRequestsApi.contactChanges(page);
    request.then((response) => {
      if (!current) return;
      if (page > 1 && response.meta.total_pages < page) {
        setPage(Math.max(1, response.meta.total_pages));
        return;
      }
      setRows(response.data);
      setMeta(response.meta);
      setLoading(false);
    }).catch((err: unknown) => {
      if (!current) return;
      setRows([]);
      setMeta(undefined);
      if (staffCompanyId && apiErrorCode(err) === 'feature_off') {
        setFeatureOff(true);
      } else {
        setError(err instanceof Error ? err.message : 'Could not load contact changes.');
      }
      setLoading(false);
    });
    return () => { current = false; };
  }, [staffCompanyId, kind, status, searchFilter, page, reload]);

  const totalCount = meta?.total_count ?? 0;

  const confirm = async (target: { id: number } | { throughId: number }) => {
    if (!staffCompanyId) return;
    setSaving(true);
    setError('');
    setNotice('');
    try {
      const result = 'id' in target
        ? await staffEmployeeContactChangesApi.confirm(staffCompanyId, target.id)
        : await staffEmployeeContactChangesApi.confirmAll(staffCompanyId, { kind, search: searchFilter }, target.throughId);
      const count = result.confirmed_count;
      setNotice(count ? `${count} ${count === 1 ? 'change' : 'changes'} confirmed on payroll.` : 'Already confirmed on payroll.');
      setReload((value) => value + 1);
      setConfirmAllOpen(false);
    } catch (err) {
      setConfirmAllOpen(false);
      // Updates were switched off after this list loaded: show the same
      // turned-off message and drop the stale rows and controls.
      if (apiErrorCode(err) === 'feature_off') {
        setRows([]);
        setMeta(undefined);
        setFeatureOff(true);
      } else {
        setError(err instanceof Error ? err.message : 'Could not confirm these changes.');
      }
    } finally {
      setSaving(false);
    }
  };

  if (staffCompanyId && featureOff) {
    return (
      <div role="status" className="space-y-1 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-800">
        <p className="font-semibold text-neutral-900 [overflow-wrap:anywhere]">
          Employee contact and address updates aren't turned on for {companyName || 'this company'}.
        </p>
        <p>When they are, changes employees make in the employee app appear here for you to confirm on payroll.</p>
        <p><EmployeeAppTurnOnStep companyId={staffCompanyId} audience="admin" /></p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {staffCompanyId && (
        <div className="flex flex-wrap items-end gap-3">
          <label className="w-full space-y-1 text-sm font-medium sm:w-auto">
            <span>Employee</span>
            <Input value={search} placeholder="Search by name" disabled={saving} onChange={(event) => { setSearch(event.target.value); setPage(1); }} />
          </label>
          <label className="space-y-1 text-sm font-medium">
            <span>Change type</span>
            <Select value={kind ?? ''} disabled={saving} onChange={(event) => { setKind((event.target.value || undefined) as ContactActivityFilters['kind']); setPage(1); }}>
              <option value="">All changes</option>
              <option value="address">Address</option>
              <option value="contact">Contact details</option>
              <option value="delivery_consent">Delivery consent</option>
            </Select>
          </label>
          <label className="space-y-1 text-sm font-medium">
            <span>Status</span>
            <Select value={status} disabled={saving} onChange={(event) => { setStatus(event.target.value as typeof status); setPage(1); }}>
              <option value="unconfirmed">To confirm</option>
              <option value="confirmed">Confirmed</option>
            </Select>
          </label>
          {status === 'unconfirmed' && (
            <Button className="sm:ml-auto" variant="outline" disabled={loading || saving || !meta?.through_id} onClick={() => setConfirmAllOpen(true)}>
              Confirm all
            </Button>
          )}
        </div>
      )}

      {error && <ActionFeedback tone="error" message={error} />}
      {notice && <p role="status" className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">{notice}</p>}
      {loading && <p role="status" className="py-5 text-sm text-neutral-600">Loading contact changes…</p>}
      {!loading && !error && rows.length === 0 && (
        <p className="py-5 text-sm text-neutral-600">
          {staffCompanyId && status === 'unconfirmed' ? 'No changes to confirm.' : 'No contact changes found.'}
        </p>
      )}
      {!loading && rows.map((entry) => (
        <Card key={entry.id}>
          <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-3 space-y-0">
            <div className="min-w-0">
              <CardTitle className="break-words text-base">{entry.employee_name}</CardTitle>
              <p className="mt-1 break-words text-sm text-neutral-600">
                {entry.change_kind === 'address' ? 'Address' : entry.change_kind === 'delivery_consent' ? 'Delivery consent' : 'Contact details'} · {entry.changed_by_name || 'Account unavailable'} · {new Date(entry.created_at).toLocaleDateString()}
              </p>
            </div>
            {staffCompanyId && !entry.confirmed_at && (
              <Button size="sm" variant="outline" disabled={saving} onClick={() => void confirm({ id: entry.id })}>
                Confirmed on payroll
              </Button>
            )}
            {entry.confirmed_at && (
              <p className="break-words text-sm text-success-700">
                Confirmed {new Date(entry.confirmed_at).toLocaleDateString()}{entry.confirmed_by_name ? ` by ${entry.confirmed_by_name}` : ''}
              </p>
            )}
          </CardHeader>
          <CardContent>
            <ChangeComparison before={entry.before_values} after={entry.after_values} />
          </CardContent>
        </Card>
      ))}
      {!loading && meta && meta.total_pages > 1 && (
        <nav aria-label="Contact change pages" className="flex items-center justify-between gap-2 text-sm">
          <Button variant="outline" disabled={page <= 1 || saving} onClick={() => setPage(page - 1)}>Previous</Button>
          <span>Page {page} of {meta.total_pages}</span>
          <Button variant="outline" disabled={page >= meta.total_pages || saving} onClick={() => setPage(page + 1)}>Next</Button>
        </nav>
      )}
      <Dialog open={confirmAllOpen} onOpenChange={(open) => { if (!saving) setConfirmAllOpen(open); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Confirm all matching changes?</DialogTitle>
            <DialogDescription>
              Mark {totalCount} {totalCount === 1 ? 'change' : 'changes'} matching these filters as confirmed on payroll{totalCount > 1 ? ', including changes on other pages' : ''}.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" disabled={saving} onClick={() => setConfirmAllOpen(false)}>Cancel</Button>
            <Button disabled={saving || !meta?.through_id} onClick={() => { if (meta?.through_id) void confirm({ throughId: meta.through_id }); }}>{saving ? 'Confirming…' : 'Confirm all'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
