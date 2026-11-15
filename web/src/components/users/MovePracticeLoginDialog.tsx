import { useState } from 'react';
import { FlaskConical, RefreshCw } from 'lucide-react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { usersApi, type CompanyListItem, type InvitationDeliveryResponse } from '@/services/api';
import type { User } from '@/types';
import { practiceMoveTargets } from '@/lib/user-company-access';

interface MovePracticeLoginDialogProps {
  user: User;
  companies: CompanyListItem[];
  loadingCompanies: boolean;
  loadError?: string | null;
  onRefreshCompanies: () => void;
  onClose: () => void;
  onMoved: (result: { user: User; fromName: string; toName: string; invitation?: InvitationDeliveryResponse }) => void;
}

// Moves a practice-only login whose copy has closed to a ready practice copy.
// The server re-checks every rule; this dialog only offers eligible copies.
export function MovePracticeLoginDialog({ user, companies, loadingCompanies, loadError, onRefreshCompanies, onClose, onMoved }: MovePracticeLoginDialogProps) {
  const targets = practiceMoveTargets(companies, user.organization_id, user.practice_company_id, user.practice_company_source_id);
  const [chosenId, setTargetId] = useState<number | null>(null);
  // One eligible copy is chosen for the admin, including after a refresh.
  const targetId = chosenId ?? (targets.length === 1 ? targets[0].id : null);
  const [activate, setActivate] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const target = targets.find(company => company.id === targetId) ?? null;
  const currentCopy = user.practice_company_name || 'its practice copy';

  const handleMove = async () => {
    if (!target) return;
    setSaving(true);
    setError(null);
    try {
      const response = await usersApi.movePracticeCopy(user.id, { company_id: target.id, activate });
      onMoved({
        user: response.data,
        fromName: response.moved_from?.name ?? currentCopy,
        toName: target.name,
        invitation: response.invitation_delivery_status ? response as InvitationDeliveryResponse : undefined,
      });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The login could not be moved.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open onOpenChange={open => { if (!open && !saving) onClose(); }}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Move {user.name} to another practice copy</DialogTitle>
          <DialogDescription>
            {currentCopy} is {user.practice_copy_closed_reason || 'closed'}. Moving gives this login access to one ready practice copy instead.
            Submissions and files it left in {currentCopy} keep its name.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4 py-4">
          {error && <ActionFeedback tone="error" message={error} />}
          <fieldset>
            <legend className="text-sm font-medium text-neutral-700">Ready copies of the same client</legend>
            {targets.length === 0 ? (
              <div className="mt-2 rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-600">
                {loadError
                  ? <p className="text-danger-700">The practice copies could not be loaded: {loadError}</p>
                  : <p>No ready practice copy of the same client is available. Make one from Client Management, then refresh.</p>}
                <Button className="mt-3" size="sm" variant="outline" onClick={onRefreshCompanies} disabled={loadingCompanies}>
                  <RefreshCw className={`mr-1 h-4 w-4 ${loadingCompanies ? 'animate-spin' : ''}`} aria-hidden="true" />
                  {loadingCompanies ? 'Refreshing…' : loadError ? 'Try again' : 'Refresh'}
                </Button>
              </div>
            ) : (
              <div className="mt-2 space-y-2">
                {targets.map(company => (
                  <label
                    key={company.id}
                    className={`flex cursor-pointer items-center gap-3 rounded-lg border p-3 text-sm transition-colors ${
                      targetId === company.id ? 'border-primary-300 bg-primary-50' : 'border-neutral-200 bg-white hover:bg-neutral-50'
                    }`}
                  >
                    <input
                      type="radio"
                      name="practice-move-target"
                      checked={targetId === company.id}
                      onChange={() => setTargetId(company.id)}
                      className="h-4 w-4 border-neutral-300 text-primary-600 focus:ring-primary-500"
                    />
                    <FlaskConical className="h-4 w-4 shrink-0 text-amber-700" aria-hidden="true" />
                    <span className="min-w-0">
                      <span className="block break-words font-medium text-neutral-900">{company.name}</span>
                      <span className="block text-xs text-neutral-600">
                        {[
                          company.migration_source_company_name && `Copy of ${company.migration_source_company_name}`,
                          company.test_workspace_expires_at && `open until ${new Date(company.test_workspace_expires_at).toLocaleDateString()}`,
                        ].filter(Boolean).join(' · ')}
                      </span>
                    </span>
                  </label>
                ))}
              </div>
            )}
          </fieldset>
          <label className="flex items-start gap-3 text-sm text-neutral-700">
            <input
              type="checkbox"
              checked={activate}
              onChange={event => setActivate(event.target.checked)}
              className="mt-0.5 h-4 w-4 rounded border-neutral-300 text-primary-600 focus:ring-primary-500"
            />
            <span>
              Activate the login now
              <span className="block text-xs text-neutral-600">
                {user.invitation_pending ? 'A fresh invitation email will be sent.' : 'They can sign in with their existing account.'}
              </span>
            </span>
          </label>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void handleMove()} disabled={!target || saving}>
            {saving ? 'Moving…' : activate ? 'Move and activate' : 'Move login'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
