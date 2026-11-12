import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { BellRing, Mail, X } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { portalAlertRecipientsApi, type PortalAlertRecipients } from '@/services/portal-notifications-api';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function roleLabel(role: string): string {
  if (role === 'org_admin' || role === 'admin') return 'Organization Admin';
  return role.split('_').map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(' ');
}

interface Props {
  companyId: number;
  readOnly?: boolean;
  onRecipientCountChange?: (count: number | null) => void;
}

/** The selected client's staff-side portal alert recipients. */
export function PortalAlertRecipientsPanel({ companyId, readOnly = false, onRecipientCountChange }: Props): ReactElement {
  const [settings, setSettings] = useState<PortalAlertRecipients | null>(null);
  const [selectedIds, setSelectedIds] = useState<number[]>([]);
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
      setLoadError(caught instanceof Error ? caught.message : 'Could not load alert recipients.');
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
          <ActionFeedback tone="error" message={`Alert recipients unavailable. ${loadError}`} />
          <Button variant="outline" onClick={() => void load()}>Retry alert recipients</Button>
        </CardContent>
      </Card>
    );
  }
  if (!settings) return <p className="text-sm text-neutral-500">Loading alert recipients…</p>;

  const savedIds = settings.eligible_users.filter((user) => user.selected).map((user) => user.id);
  const dirty = savedIds.length !== selectedIds.length || savedIds.some((id) => !selectedIds.includes(id))
    || settings.extra_emails.join('\n') !== emails.join('\n') || settings.ineligible_listed_users.length > 0;
  const nobody = selectedIds.length === 0 && emails.length === 0;
  const atEmailLimit = emails.length >= settings.max_extra_emails;

  const toggle = (id: number): void => {
    setSaved(false);
    setSelectedIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
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
      const response = await portalAlertRecipientsApi.update(requested, { user_ids: selectedIds, emails });
      if (!isCurrent()) return;
      apply(response.data);
      setSaved(true);
    } catch (caught) {
      if (isCurrent()) setSaveError(caught instanceof Error ? caught.message : 'Could not save alert recipients.');
    } finally {
      if (isCurrent()) setSaving(false);
    }
  };

  return (
    <Card id="portal-alert-recipients">
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><BellRing className="h-5 w-5 shrink-0 text-primary-700" />Portal Alert Recipients</CardTitle>
        <CardDescription>
          Who gets an email when this client sends a message, uploads files or submits an employee change.
          Each person&apos;s own Immediate, Daily digest or Off setting still applies.
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
            <p className="font-semibold">No one receives this client&apos;s portal alerts.</p>
            <p>New messages, uploads and employee changes are recorded as skipped (no recipients) until you add someone.
              {settings.unnotified_event_count > 0 && ` ${settings.unnotified_event_count} in the last 30 days had nobody to notify.`}</p>
          </div>
        )}

        <fieldset className="space-y-2" disabled={readOnly || saving}>
          <legend className="text-sm font-semibold text-neutral-900">Staff</legend>
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
                  <span className="min-w-0">
                    <span className="block text-sm font-medium text-neutral-900">{user.name}</span>
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
            For people without an app account. They get the same generic alert; the link still asks them to sign in.
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
        {saved && <ActionFeedback tone="success" message="Alert recipients saved." />}
        {!readOnly && (
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Button onClick={() => void save()} disabled={!dirty || saving} loading={saving} loadingLabel="Saving…">Save recipients</Button>
            {dirty && nobody && <p className="text-xs text-amber-900">Saving with nobody selected leaves this client without alerts.</p>}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
