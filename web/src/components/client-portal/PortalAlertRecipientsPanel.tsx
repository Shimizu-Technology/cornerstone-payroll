import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { BellRing, Mail, X } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { roleLabel } from '@/lib/role-labels';
import { portalAlertRecipientsApi, type PortalAlertRecipients } from '@/services/portal-notifications-api';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

interface Props {
  companyId: number;
  readOnly?: boolean;
  onRecipientCountChange?: (count: number | null) => void;
}

/** The selected client's Cornerstone account team (staff-side portal alert recipients). */
export function PortalAlertRecipientsPanel({ companyId, readOnly = false, onRecipientCountChange }: Props): ReactElement {
  const [settings, setSettings] = useState<PortalAlertRecipients | null>(null);
  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  const [leadUserId, setLeadUserId] = useState<number | null>(null);
  const [backupUserId, setBackupUserId] = useState<number | null>(null);
  const [emails, setEmails] = useState<string[]>([]);
  const [draftEmail, setDraftEmail] = useState('');
  const [emailError, setEmailError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const companyRef = useRef(companyId);
  companyRef.current = companyId;
  const countCallbackRef = useRef(onRecipientCountChange);
  countCallbackRef.current = onRecipientCountChange;
  // Only the newest load may apply. A save, a company change or unmounting
  // invalidates older loads, so a stale response can never replace saved or
  // in-progress choices, or report another client's recipient count.
  const loadGenerationRef = useRef(0);
  const mountedRef = useRef(false);

  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);

  const apply = useCallback((data: PortalAlertRecipients): void => {
    setSettings(data);
    countCallbackRef.current?.(data.recipient_count);
    setSelectedIds(data.eligible_users.filter((user) => user.selected).map((user) => user.id));
    setLeadUserId(data.lead_user_id ?? data.eligible_users.find((user) => user.team_role === 'lead')?.id ?? null);
    setBackupUserId(data.backup_user_id ?? data.eligible_users.find((user) => user.team_role === 'backup')?.id ?? null);
    setEmails(data.extra_emails);
  }, []);

  const load = useCallback(async (): Promise<void> => {
    const requested = companyId;
    const generation = ++loadGenerationRef.current;
    const isCurrent = (): boolean => mountedRef.current && generation === loadGenerationRef.current && companyRef.current === requested;
    setLoadError(null);
    try {
      const response = await portalAlertRecipientsApi.get(requested);
      if (isCurrent()) apply(response.data);
    } catch (caught) {
      if (!isCurrent()) return;
      setLoadError(caught instanceof Error ? caught.message : 'Could not load Cornerstone account team.');
      countCallbackRef.current?.(null);
    }
  }, [apply, companyId]);

  useEffect(() => {
    countCallbackRef.current?.(null);
    setSettings(null);
    setSaved(false);
    setSaveError(null);
    void load();
    return () => { loadGenerationRef.current += 1; };
  }, [load]);

  if (loadError) {
    return (
      <Card id="portal-alert-recipients">
        <CardContent className="space-y-3 pt-6">
          <ActionFeedback tone="error" message={`Cornerstone account team unavailable. ${loadError}`} />
          <Button variant="outline" onClick={() => void load()}>Retry account team</Button>
        </CardContent>
      </Card>
    );
  }
  if (!settings) return <p className="text-sm text-neutral-500">Loading Cornerstone account team…</p>;

  const savedIds = settings.eligible_users.filter((user) => user.selected).map((user) => user.id);
  const savedLeadId = settings.lead_user_id ?? settings.eligible_users.find((user) => user.team_role === 'lead')?.id ?? null;
  const savedBackupId = settings.backup_user_id ?? settings.eligible_users.find((user) => user.team_role === 'backup')?.id ?? null;
  const dirty = savedIds.length !== selectedIds.length
    || savedIds.some((id) => !selectedIds.includes(id))
    || savedLeadId !== leadUserId
    || savedBackupId !== backupUserId
    || settings.extra_emails.join('\n') !== emails.join('\n')
    || settings.ineligible_listed_users.length > 0;
  const nobody = selectedIds.length === 0 && emails.length === 0;
  const missingLead = selectedIds.length > 0 && leadUserId === null;
  const needsLeadSaved = settings.needs_lead ?? (savedIds.length > 0 && savedLeadId === null);
  const atEmailLimit = emails.length >= settings.max_extra_emails;

  const toggle = (id: number): void => {
    setSaved(false);
    if (selectedIds.includes(id)) {
      if (leadUserId === id) {
        setLeadUserId(null);
        setBackupUserId(null);
      } else if (backupUserId === id) {
        setBackupUserId(null);
      }
      setSelectedIds((current) => current.filter((value) => value !== id));
    } else {
      setSelectedIds((current) => (current.includes(id) ? current : [...current, id]));
    }
  };

  const selectLead = (value: string): void => {
    setSaved(false);
    const nextId = value ? Number(value) : null;
    setLeadUserId(nextId);
    if (nextId === null) {
      setBackupUserId(null);
    } else {
      if (backupUserId === nextId) setBackupUserId(null);
      setSelectedIds((current) => (current.includes(nextId) ? current : [...current, nextId]));
    }
  };

  const selectBackup = (value: string): void => {
    setSaved(false);
    const nextId = value ? Number(value) : null;
    if (nextId !== null && leadUserId === null) return;
    setBackupUserId(nextId);
    if (nextId !== null) {
      if (leadUserId === nextId) setLeadUserId(null);
      setSelectedIds((current) => (current.includes(nextId) ? current : [...current, nextId]));
    }
  };

  const addEmail = (event: FormEvent): void => {
    event.preventDefault();
    const email = draftEmail.trim().toLowerCase();
    if (!EMAIL_PATTERN.test(email)) return setEmailError('Enter a valid email address.');
    if (emails.includes(email)) return setEmailError('That address is already on the list.');
    if (atEmailLimit) return setEmailError(`Add up to ${settings.max_extra_emails} extra addresses.`);
    setEmailError(null);
    setSaved(false);
    setEmails((current) => [...current, email].sort());
    setDraftEmail('');
  };

  const save = async (): Promise<void> => {
    const requested = companyId;
    loadGenerationRef.current += 1;
    const isCurrent = (): boolean => mountedRef.current && companyRef.current === requested;
    setSaving(true);
    setSaveError(null);
    setEmailError(null);
    setSaved(false);
    try {
      const response = await portalAlertRecipientsApi.update(requested, {
        user_ids: selectedIds,
        emails,
        lead_user_id: leadUserId,
        backup_user_id: backupUserId,
      });
      if (!isCurrent()) return;
      apply(response.data);
      setSaved(true);
    } catch (caught) {
      if (isCurrent()) setSaveError(caught instanceof Error ? caught.message : 'Could not save Cornerstone account team.');
    } finally {
      if (isCurrent()) setSaving(false);
    }
  };

  return (
    <Card id="portal-alert-recipients">
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><BellRing className="h-5 w-5 shrink-0 text-primary-700" />Cornerstone account team</CardTitle>
        <CardDescription>
          Choose the Cornerstone staff assigned to this client. They receive emails when the client approves payroll,
          requests changes, sends messages, uploads files, or submits employee changes. Each person&apos;s own Immediate,
          Daily digest or Off setting still applies.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {!settings.email_delivery_enabled && (
          <p className="rounded-lg border border-blue-200 bg-blue-50 px-3 py-2 text-sm leading-6 text-blue-900">
            Email delivery is off for now. Alerts are recorded here but not sent until Cornerstone turns email on.
          </p>
        )}
        {settings.recipient_count === 0 && (
          <div role="alert" className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm leading-6 text-amber-950">
            <p className="font-semibold">No Cornerstone account team is assigned to this client.</p>
            <p>Payroll approvals, change requests, messages, uploads, and employee changes are recorded as skipped (no recipients) until you assign someone.
              {settings.unnotified_event_count > 0 && ` ${settings.unnotified_event_count} in the last 30 days had nobody to notify.`}</p>
          </div>
        )}
        {settings.recipient_count > 0 && needsLeadSaved && (
          <div role="alert" className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm leading-6 text-amber-950">
            <p className="font-semibold">This Cornerstone account team needs an Account lead.</p>
            <p>Choose an Account lead from the assigned staff and save so someone owns this client&apos;s payroll alerts.</p>
          </div>
        )}

        {settings.eligible_users.length > 0 && (
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor={`account-team-lead-${companyId}`} className="mb-1 block text-xs font-semibold text-neutral-700">
                Account lead
              </label>
              <Select
                id={`account-team-lead-${companyId}`}
                value={leadUserId ? String(leadUserId) : ''}
                disabled={readOnly || saving}
                onChange={(event) => selectLead(event.target.value)}
              >
                <option value="">None selected</option>
                {settings.eligible_users.map((user) => (
                  <option key={user.id} value={user.id}>{user.name} ({roleLabel(user.role)})</option>
                ))}
              </Select>
            </div>
            <div>
              <label htmlFor={`account-team-backup-${companyId}`} className="mb-1 block text-xs font-semibold text-neutral-700">
                Backup (optional)
              </label>
              <Select
                id={`account-team-backup-${companyId}`}
                value={backupUserId ? String(backupUserId) : ''}
                disabled={readOnly || saving || !leadUserId}
                onChange={(event) => selectBackup(event.target.value)}
              >
                <option value="">None selected</option>
                {settings.eligible_users.map((user) => (
                  <option key={user.id} value={user.id}>{user.name} ({roleLabel(user.role)})</option>
                ))}
              </Select>
            </div>
          </div>
        )}

        <fieldset className="space-y-2" disabled={readOnly || saving}>
          <legend className="text-sm font-semibold text-neutral-900">Assigned staff</legend>
          <p className="text-xs text-neutral-600">Active staff in your organization who can open this client.</p>
          {settings.eligible_users.length === 0 && <p className="text-sm text-neutral-600">No eligible staff members.</p>}
          <ul className="divide-y divide-neutral-100 rounded-lg border border-neutral-200">
            {settings.eligible_users.map((user) => (
              <li key={user.id}>
                <label className="flex min-h-11 cursor-pointer items-start gap-3 px-3 py-2.5 hover:bg-neutral-50">
                  <input
                    type="checkbox"
                    className="mt-1 h-4 w-4 shrink-0 rounded border-neutral-300 text-primary-600"
                    checked={selectedIds.includes(user.id)}
                    onChange={() => toggle(user.id)}
                  />
                  <span className="min-w-0 flex-1">
                    <span className="flex flex-wrap items-center gap-2 text-sm font-medium text-neutral-900">
                      <span>{user.name}</span>
                      {leadUserId === user.id && <Badge variant="info">Lead</Badge>}
                      {backupUserId === user.id && <Badge variant="default">Backup</Badge>}
                    </span>
                    <span className="block break-all text-xs text-neutral-600">{roleLabel(user.role)} · {user.email}</span>
                  </span>
                </label>
              </li>
            ))}
          </ul>
          {settings.ineligible_listed_users.length > 0 && (
            <p className="text-xs leading-5 text-amber-900">
              No longer eligible and will be removed when you save: {settings.ineligible_listed_users.map((user) => user.name).join(', ')}.
            </p>
          )}
        </fieldset>

        <div className="space-y-2">
          <p className="text-sm font-semibold text-neutral-900">Extra email addresses</p>
          <p className="text-xs leading-5 text-neutral-600">
            For people without an app account. They get the same alert email; the link still asks them to sign in.
          </p>
          {emails.length > 0 && (
            <ul className="space-y-1.5">
              {emails.map((email) => (
                <li key={email} className="flex items-center gap-2 rounded-lg border border-neutral-200 px-3 py-1.5">
                  <Mail className="h-4 w-4 shrink-0 text-neutral-500" />
                  <span className="min-w-0 flex-1 break-all text-sm text-neutral-900">{email}</span>
                  {!readOnly && (
                    <button
                      type="button"
                      className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
                      aria-label={`Remove ${email}`}
                      disabled={saving}
                      onClick={() => { setSaved(false); setEmails((current) => current.filter((value) => value !== email)); }}
                    >
                      <X className="h-4 w-4" />
                    </button>
                  )}
                </li>
              ))}
            </ul>
          )}
          {!readOnly && (
            <form className="flex flex-col gap-2 sm:flex-row" onSubmit={addEmail} noValidate>
              <label className="sr-only" htmlFor={`extra-alert-email-${companyId}`}>Extra email address</label>
              <div className="sm:w-80">
                <Input
                  id={`extra-alert-email-${companyId}`}
                  type="email"
                  inputMode="email"
                  autoComplete="off"
                  value={draftEmail}
                  placeholder="name@example.com"
                  disabled={saving || atEmailLimit}
                  aria-invalid={emailError ? true : undefined}
                  onChange={(event) => { setDraftEmail(event.target.value); setEmailError(null); }}
                />
              </div>
              <Button type="submit" variant="outline" disabled={saving || atEmailLimit || !draftEmail.trim()}>Add address</Button>
            </form>
          )}
          {emailError && <p className="text-xs text-red-700" role="alert">{emailError}</p>}
        </div>

        {saveError && <ActionFeedback tone="error" message={saveError} />}
        {saved && <ActionFeedback tone="success" message="Account team saved." />}
        {!readOnly && (
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Button onClick={() => void save()} disabled={!dirty || saving || missingLead} loading={saving} loadingLabel="Saving…">Save account team</Button>
            {missingLead && <p className="text-xs text-amber-900">Choose an Account lead before saving.</p>}
            {dirty && nobody && <p className="text-xs text-amber-900">Saving with nobody selected leaves this client without an account team.</p>}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

export const ClientAccountTeamPanel = PortalAlertRecipientsPanel;
