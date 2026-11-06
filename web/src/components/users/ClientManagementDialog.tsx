import { useCallback, useEffect, useRef, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { companyAssignmentsApi, type CompanyAssignment } from '@/services/api';
import type { User } from '@/types';
import { Button } from '@/components/ui/button';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter } from '@/components/ui/dialog';
import { formatGuamDateTime } from '@/lib/utils';

function assignmentExpired(assignment: CompanyAssignment): boolean {
  if (!assignment.expires_at) return false;
  const expiry = Date.parse(assignment.expires_at);
  return !Number.isFinite(expiry) || expiry <= Date.now();
}

export function ClientManagementDialog({ accountant, onClose }: { accountant: User; onClose: () => void }) {
  const { user } = useAuth();
  const allowed = ['admin', 'org_admin', 'super_admin'].includes(user?.role ?? '') && user?.id !== accountant.id && accountant.role === 'accountant';
  const [assignments, setAssignments] = useState<CompanyAssignment[]>([]);
  const [loading, setLoading] = useState(true);
  const [confirmed, setConfirmed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [saving, setSaving] = useState<number | null>(null);
  const [, tick] = useState(0);
  const generation = useRef(0);
  const load = useCallback(async ({ refresh = false }: { refresh?: boolean } = {}) => {
    const request = ++generation.current;
    setLoading(true);
    if (!refresh) setAssignments([]);
    setConfirmed(false);
    setError(null);
    try {
      const response = await companyAssignmentsApi.list(accountant.id);
      if (request !== generation.current) return false;
      const loaded = response.data.filter(assignment => assignment.user_id === accountant.id);
      setAssignments(loaded);
      setConfirmed(true);
      return loaded;
    } catch (caught) {
      if (request === generation.current) setError(caught instanceof Error ? caught.message : 'Could not load client management access.');
      return false;
    } finally {
      if (request === generation.current) setLoading(false);
    }
  }, [accountant.id]);
  useEffect(() => {
    if (allowed) void load();
    return () => { generation.current += 1; };
  }, [allowed, load]);
  useEffect(() => {
    const expiries = assignments.map(assignment => Date.parse(assignment.expires_at ?? '')).filter(expiry => expiry > Date.now());
    if (!expiries.length) return;
    const timer = window.setTimeout(() => tick(current => current + 1), Math.min(Math.max(Math.min(...expiries) - Date.now() + 10, 0), 2_147_483_647));
    return () => window.clearTimeout(timer);
  });
  const update = async (assignment: CompanyAssignment) => {
    if (!allowed || !confirmed || loading || assignment.user_id !== accountant.id || saving !== null || (!assignment.client_management && assignmentExpired(assignment))) return;
    const request = generation.current;
    setSaving(assignment.id);
    setError(null);
    setNotice(null);
    try {
      await companyAssignmentsApi.updateClientManagement(assignment.id, !assignment.client_management);
      if (request !== generation.current) return;
      // Re-read authoritative access, including assignment revocation/expiry.
      const loaded = await load({ refresh: true });
      if (loaded && request + 1 === generation.current) {
        const confirmed = loaded.find(current => current.id === assignment.id);
        if (confirmed && Boolean(confirmed.client_management) === !assignment.client_management && (!confirmed.client_management || !assignmentExpired(confirmed))) {
          setNotice(`Client management ${confirmed.client_management ? 'granted' : 'revoked'} for ${assignment.company_name}.`);
        } else {
          setError('Access changed while saving. Review the current client access before trying again.');
        }
      }
    } catch (caught) {
      if (request === generation.current) setError(caught instanceof Error ? caught.message : 'Could not change client management. Retry this client action.');
    } finally {
      setSaving(null);
    }
  };
  if (!allowed) return null;
  return <Dialog open onOpenChange={open => { if (!open && saving === null) onClose(); }}>
    <DialogContent className="max-w-xl">
      <DialogHeader>
        <DialogTitle>Client management for {accountant.name}</DialogTitle>
        <DialogDescription>Client management permits client setup, check settings, and employee administration. Grant or revoke access for one assigned client at a time. Their role stays Accountant. Users, source credentials, and firm-wide settings stay restricted. These changes are separate from Save on the user profile.</DialogDescription>
      </DialogHeader>
      <div className="max-h-[60vh] space-y-3 overflow-y-auto py-4" aria-busy={loading || saving !== null}>
        {error && <ActionFeedback tone="error" message={error} />}
        {notice && <ActionFeedback tone="success" message={notice} />}
        {loading && <p role="status">Loading assigned client access…</p>}
        <>
          {error && <Button variant="outline" disabled={saving !== null} onClick={() => void load()}>Reload client access</Button>}
          {!loading && !assignments.length && !error && <p>No assigned clients. Assign and save a client on the user profile first.</p>}
          {assignments.map(assignment => {
            const expired = assignmentExpired(assignment);
            return <section key={assignment.id} className="rounded-xl border border-neutral-200 p-3" aria-label={assignment.company_name}>
              <h3 className="break-words font-semibold">{assignment.company_name}</h3>
              <p className="mt-1 text-sm text-neutral-600">Client management: {expired ? 'Unavailable — assignment expired' : assignment.client_management ? 'Granted' : 'Not granted'}</p>
              {assignment.expires_at && Number.isFinite(Date.parse(assignment.expires_at)) && <p className="mt-1 text-sm text-neutral-600">Assignment {expired ? 'expired' : 'expires'} {formatGuamDateTime(assignment.expires_at)}.</p>}
              {assignment.test_workspace && <p className="mt-1 text-sm text-neutral-600">Test workspace permissions and safety rules still apply.</p>}
              <Button className="mt-3 aria-disabled:opacity-50" variant="outline" disabled={!assignment.client_management && (expired || accountant.active === false)} aria-disabled={loading || saving !== null || !confirmed || undefined} onClick={() => void update(assignment)} aria-label={`${assignment.client_management ? 'Revoke' : 'Grant'} Client management for ${assignment.company_name}`}>
                {saving === assignment.id ? 'Saving…' : assignment.client_management ? 'Revoke Client management' : 'Grant Client management'}
              </Button>
            </section>;
          })}
        </>
      </div>
      <DialogFooter><Button variant="outline" disabled={saving !== null} onClick={onClose}>Close</Button></DialogFooter>
    </DialogContent>
  </Dialog>;
}
