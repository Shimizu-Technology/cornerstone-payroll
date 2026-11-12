import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { useCompany } from '@/contexts/CompanyContext';
import { formatGuamDateTime } from '@/lib/utils';
import {
  notificationSettingsApi,
  type NotificationDeliveryMode,
  type NotificationSettings as Settings,
  type RecentPortalAlert,
} from '@/services/portal-notifications-api';

const STATUS_LABELS: Record<RecentPortalAlert['status'], { label: string; variant: 'default' | 'success' | 'warning' | 'danger' | 'info' }> = {
  pending: { label: 'Waiting to send', variant: 'info' },
  sent: { label: 'Sent', variant: 'success' },
  failed: { label: 'Failed', variant: 'danger' },
  skipped: { label: 'Not emailed', variant: 'default' },
};

const SKIP_REASONS: Record<string, string> = {
  no_recipients: 'Nobody was set up to receive it.',
  preference_off: 'Your email setting for this was off.',
  coalesced: 'Covered by an earlier alert for the same conversation.',
  already_read: 'You opened it before the email was sent.',
  recipient_removed: 'You were removed from this client’s alert list.',
  access_revoked: 'Your access changed before it was sent.',
  resource_unavailable: 'The item is no longer available.',
  email_delivery_disabled: 'Email delivery is off for now.',
  email_not_configured: 'Email is not set up yet.',
  staging_contained: 'Held in the staging environment.',
};

export function NotificationSettings() {
  const navigate = useNavigate();
  const { switchCompany } = useCompany();
  const [settings, setSettings] = useState<Settings | null>(null);
  const [modes, setModes] = useState<Record<string, NotificationDeliveryMode>>({});
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  // A late or repeated load must never overwrite choices the person is making.
  const editedRef = useRef(false);

  const apply = (data: Settings, { fromLoad = false } = {}) => {
    setSettings(data);
    if (fromLoad && editedRef.current) return;
    editedRef.current = false;
    setModes(Object.fromEntries(data.categories.map((category) => [category.key, category.delivery_mode])));
  };

  const load = useCallback(async () => {
    setLoadError(null);
    try {
      apply((await notificationSettingsApi.get()).data, { fromLoad: true });
    } catch (caught) {
      setLoadError(caught instanceof Error ? caught.message : 'Could not load notification settings.');
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const dirty = Boolean(settings?.categories.some((category) => modes[category.key] !== category.delivery_mode));

  const save = async () => {
    setSaving(true);
    setSaveError(null);
    setSaved(false);
    try {
      apply((await notificationSettingsApi.update(modes)).data);
      setSaved(true);
    } catch (caught) {
      setSaveError(caught instanceof Error ? caught.message : 'Could not save notification settings.');
    } finally {
      setSaving(false);
    }
  };

  const openClient = (companyId: number) => {
    if (switchCompany(companyId)) navigate('/settings/client-documents');
  };

  return (
    <div>
      <Header title="Notifications" description="Choose how Cornerstone Payroll emails you about portal activity." mobileSticky={false} />
      <div className="mx-auto max-w-4xl space-y-6 p-4 sm:p-6 lg:p-8">
        {loadError && (
          <div className="space-y-3">
            <ActionFeedback tone="error" message={`Notification settings unavailable. ${loadError}`} />
            <Button variant="outline" onClick={() => void load()}>Retry</Button>
          </div>
        )}
        {!settings && !loadError && <p className="text-sm text-neutral-500">Loading notification settings…</p>}

        {settings && (
          <>
            {!settings.email_delivery_enabled && (
              <p className="rounded-lg border border-blue-200 bg-blue-50 px-3 py-2 text-sm leading-6 text-blue-900">
                Email delivery is off for now. Your choices are saved and alerts are recorded, but no email is sent until Cornerstone turns email on.
              </p>
            )}

            <Card>
              <CardHeader>
                <CardTitle>Email alerts</CardTitle>
                <CardDescription>
                  Emails never include names, messages or file details, only a link to sign in.
                  Daily digests arrive at {settings.digest_time_label}. Unread counts in the app stay on either way.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <ul className="divide-y divide-neutral-100">
                  {settings.categories.map((category) => (
                    <li key={category.key} className="flex flex-col gap-2 py-3 first:pt-0 sm:flex-row sm:items-center sm:justify-between sm:gap-6">
                      <div className="min-w-0">
                        <label htmlFor={`notification-${category.key}`} className="text-sm font-semibold text-neutral-900">{category.label}</label>
                        <p className="text-xs leading-5 text-neutral-600">{category.description}</p>
                      </div>
                      <Select
                        id={`notification-${category.key}`}
                        className="sm:w-48"
                        value={modes[category.key]}
                        disabled={saving}
                        onChange={(event) => { editedRef.current = true; setSaved(false); setModes((current) => ({ ...current, [category.key]: event.target.value as NotificationDeliveryMode })); }}
                      >
                        <option value="immediate">Immediately{category.default_mode === 'immediate' ? ' (recommended)' : ''}</option>
                        <option value="digest">Daily digest{category.default_mode === 'digest' ? ' (recommended)' : ''}</option>
                        <option value="off">Off</option>
                      </Select>
                    </li>
                  ))}
                </ul>
                {saveError && <ActionFeedback tone="error" message={saveError} />}
                {saved && <ActionFeedback tone="success" message="Notification settings saved." />}
                <Button onClick={() => void save()} disabled={!dirty || saving} loading={saving} loadingLabel="Saving…">Save settings</Button>
              </CardContent>
            </Card>

            {settings.administration && (
              <Card>
                <CardHeader>
                  <CardTitle>Clients with no alert recipients</CardTitle>
                  <CardDescription>Portal work from the last 30 days that nobody on staff was set up to hear about.</CardDescription>
                </CardHeader>
                <CardContent>
                  {settings.administration.clients_without_recipients.length === 0
                    ? <p className="text-sm text-neutral-600">Every client with recent portal activity has alert recipients.</p>
                    : (
                      <ul className="divide-y divide-neutral-100">
                        {settings.administration.clients_without_recipients.map((client) => (
                          <li key={client.company_id} className="flex flex-col gap-2 py-3 first:pt-0 sm:flex-row sm:items-center sm:justify-between">
                            <div className="min-w-0">
                              <p className="break-words text-sm font-semibold text-neutral-900">{client.company_name || 'Client'}</p>
                              <p className="text-xs text-neutral-600">
                                {client.event_count} {client.event_count === 1 ? 'item' : 'items'} with nobody notified · latest {formatGuamDateTime(client.last_occurred_at)}
                              </p>
                            </div>
                            <Button variant="outline" onClick={() => openClient(client.company_id)}>Choose recipients</Button>
                          </li>
                        ))}
                      </ul>
                    )}
                </CardContent>
              </Card>
            )}

            <Card>
              <CardHeader>
                <CardTitle>Recent alerts</CardTitle>
                <CardDescription>Your last {settings.recent_alerts.length || 20} portal alerts and what happened to each email.</CardDescription>
              </CardHeader>
              <CardContent>
                {settings.recent_alerts.length === 0
                  ? <p className="text-sm text-neutral-600">No portal alerts yet.</p>
                  : (
                    <ul className="divide-y divide-neutral-100">
                      {settings.recent_alerts.map((alert) => {
                        const status = STATUS_LABELS[alert.status];
                        return (
                          <li key={alert.id} className="flex flex-col gap-1.5 py-3 first:pt-0 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
                            <div className="min-w-0">
                              <p className="text-sm font-semibold text-neutral-900">{alert.label}</p>
                              <p className="break-words text-xs text-neutral-600">
                                {[alert.company_name, formatGuamDateTime(alert.occurred_at)].filter(Boolean).join(' · ')}
                              </p>
                              {alert.status === 'skipped' && alert.skip_reason && (
                                <p className="text-xs text-neutral-600">{SKIP_REASONS[alert.skip_reason] || 'Not emailed.'}</p>
                              )}
                              {alert.status === 'pending' && (
                                <p className="text-xs text-neutral-600">
                                  {alert.delivery_mode === 'digest' ? 'In the next daily digest' : 'Sending shortly'} · after {formatGuamDateTime(alert.deliver_after)}
                                </p>
                              )}
                            </div>
                            <Badge variant={status.variant}>{status.label}</Badge>
                          </li>
                        );
                      })}
                    </ul>
                  )}
              </CardContent>
            </Card>
          </>
        )}
      </div>
    </div>
  );
}
