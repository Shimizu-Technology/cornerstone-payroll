import { useState, useEffect, useCallback } from 'react';
import { Bell, Plus, X, Send, Trash2, History, Mail, Clock, AlertTriangle } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { payrollReminderApi } from '@/services/api';
import type { PayrollReminderConfig, PayrollReminderLog } from '@/services/api';

export default function PayrollReminders() {
  const [config, setConfig] = useState<PayrollReminderConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  // Editable form state
  const [enabled, setEnabled] = useState(false);
  const [recipients, setRecipients] = useState<string[]>([]);
  const [newEmail, setNewEmail] = useState('');
  const [daysBefore, setDaysBefore] = useState(3);
  const [sendOverdue, setSendOverdue] = useState(true);

  // Logs
  const [logs, setLogs] = useState<PayrollReminderLog[]>([]);
  const [logsLoading, setLogsLoading] = useState(false);
  const [showLogs, setShowLogs] = useState(false);

  const loadConfig = useCallback(async () => {
    try {
      const data = await payrollReminderApi.getConfig();
      const c = data.payroll_reminder_config;
      setConfig(c);
      setEnabled(c.enabled);
      setRecipients(c.recipients || []);
      setDaysBefore(c.days_before_due);
      setSendOverdue(c.send_overdue_alerts);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load config');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadConfig();
  }, [loadConfig]);

  const loadLogs = async () => {
    setLogsLoading(true);
    try {
      const data = await payrollReminderApi.getLogs();
      setLogs(data.logs);
    } catch {
      // Silently handle - logs are non-critical
    } finally {
      setLogsLoading(false);
    }
  };

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    setSuccess(null);

    if (enabled && recipients.length === 0) {
      setError('At least one recipient email is required when reminders are enabled.');
      setSaving(false);
      return;
    }

    try {
      const data = await payrollReminderApi.updateConfig({
        enabled,
        recipients,
        days_before_due: daysBefore,
        send_overdue_alerts: sendOverdue,
      });
      setConfig(data.payroll_reminder_config);
      setSuccess('Reminder settings saved successfully.');
      setTimeout(() => setSuccess(null), 4000);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save settings');
    } finally {
      setSaving(false);
    }
  };

  const handleSendTest = async () => {
    setTesting(true);
    setError(null);
    setSuccess(null);

    try {
      const data = await payrollReminderApi.sendTest();
      setSuccess(data.message);
      setTimeout(() => setSuccess(null), 4000);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to send test email');
    } finally {
      setTesting(false);
    }
  };

  const addRecipient = () => {
    const email = newEmail.trim().toLowerCase();
    if (!email) return;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      setError('Please enter a valid email address.');
      return;
    }
    if (recipients.includes(email)) {
      setError('This email is already in the recipients list.');
      return;
    }
    setRecipients([...recipients, email]);
    setNewEmail('');
    setError(null);
  };

  const removeRecipient = (email: string) => {
    setRecipients(recipients.filter((r) => r !== email));
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      addRecipient();
    }
  };

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-blue-600 border-t-transparent" />
      </div>
    );
  }

  const hasChanges =
    config != null && (
      enabled !== config.enabled ||
      daysBefore !== config.days_before_due ||
      sendOverdue !== config.send_overdue_alerts ||
      JSON.stringify(recipients) !== JSON.stringify(config.recipients || [])
    );

  return (
    <div className="min-h-screen bg-neutral-50/60">
      <Header
        title="Payroll Reminders"
        description="Configure automatic email reminders for upcoming and overdue payroll processing."
      />

      <div className="mx-auto max-w-3xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        {/* Status messages */}
        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {error}
          </div>
        )}
        {success && (
          <div className="rounded-lg border border-green-200 bg-green-50 p-4 text-sm text-green-700">
            {success}
          </div>
        )}

        {/* Enable/Disable card */}
        <Card>
          <CardContent className="p-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <div className={`flex h-10 w-10 items-center justify-center rounded-lg ${enabled ? 'bg-blue-100' : 'bg-neutral-100'}`}>
                  <Bell className={`h-5 w-5 ${enabled ? 'text-blue-600' : 'text-neutral-400'}`} />
                </div>
                <div>
                  <h3 className="text-base font-semibold text-neutral-900">Email Reminders</h3>
                  <p className="text-sm text-neutral-500">
                    {enabled ? 'Active — reminders will be sent automatically' : 'Disabled — no reminders will be sent'}
                  </p>
                </div>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={enabled}
                onClick={() => setEnabled(!enabled)}
                className={`relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 ${
                  enabled ? 'bg-blue-600' : 'bg-neutral-200'
                }`}
              >
                <span
                  className={`pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out ${
                    enabled ? 'translate-x-5' : 'translate-x-0'
                  }`}
                />
              </button>
            </div>
          </CardContent>
        </Card>

        {/* Recipients card */}
        <Card>
          <CardContent className="space-y-4 p-6">
            <div className="flex items-center gap-2">
              <Mail className="h-4 w-4 text-neutral-500" />
              <Label className="text-base font-semibold text-neutral-900">Recipients</Label>
            </div>
            <p className="text-sm text-neutral-500">
              Add email addresses that should receive payroll reminders for this company.
            </p>

            {/* Recipient chips */}
            {recipients.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {recipients.map((email) => (
                  <span
                    key={email}
                    className="inline-flex items-center gap-1.5 rounded-full bg-blue-50 px-3 py-1 text-sm font-medium text-blue-700"
                  >
                    {email}
                    <button
                      type="button"
                      onClick={() => removeRecipient(email)}
                      className="rounded-full p-0.5 hover:bg-blue-200/60"
                    >
                      <X className="h-3.5 w-3.5" />
                    </button>
                  </span>
                ))}
              </div>
            )}

            {/* Add email input */}
            <div className="flex gap-2">
              <Input
                type="email"
                placeholder="name@company.com"
                value={newEmail}
                onChange={(e) => setNewEmail(e.target.value)}
                onKeyDown={handleKeyDown}
                className="flex-1"
              />
              <Button
                type="button"
                variant="outline"
                onClick={addRecipient}
                disabled={!newEmail.trim()}
              >
                <Plus className="mr-1.5 h-4 w-4" />
                Add
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Schedule settings card */}
        <Card>
          <CardContent className="space-y-5 p-6">
            <div className="flex items-center gap-2">
              <Clock className="h-4 w-4 text-neutral-500" />
              <Label className="text-base font-semibold text-neutral-900">Schedule</Label>
            </div>

            {/* Days before due */}
            <div className="space-y-2">
              <Label htmlFor="days-before" className="text-sm font-medium text-neutral-700">
                Send reminder
              </Label>
              <div className="flex items-center gap-2">
                <Input
                  id="days-before"
                  type="number"
                  min={1}
                  max={14}
                  value={daysBefore}
                  onChange={(e) => setDaysBefore(Math.max(1, Math.min(14, parseInt(e.target.value) || 1)))}
                  className="w-20"
                />
                <span className="text-sm text-neutral-600">day(s) before the pay date</span>
              </div>
              <p className="text-xs text-neutral-400">
                A single reminder is sent when the pay date is within this window and payroll hasn't been committed.
              </p>
            </div>

            {/* Overdue alerts */}
            <div className="flex items-start gap-3 rounded-lg border border-neutral-200 p-4">
              <div className="pt-0.5">
                <input
                  type="checkbox"
                  id="send-overdue"
                  checked={sendOverdue}
                  onChange={(e) => setSendOverdue(e.target.checked)}
                  className="h-4 w-4 rounded border-neutral-300 text-blue-600 focus:ring-blue-500"
                />
              </div>
              <div>
                <label htmlFor="send-overdue" className="text-sm font-medium text-neutral-900 cursor-pointer">
                  Send overdue alerts
                </label>
                <p className="mt-0.5 text-xs text-neutral-500">
                  If payroll is still not committed after the pay date, send an additional overdue alert.
                </p>
              </div>
            </div>

            {/* How it works info */}
            <div className="rounded-lg bg-amber-50 border border-amber-200 p-4">
              <div className="flex gap-2">
                <AlertTriangle className="h-4 w-4 text-amber-600 mt-0.5 shrink-0" />
                <div className="text-xs text-amber-800 space-y-1">
                  <p className="font-medium">How reminders work</p>
                  <ul className="list-disc pl-4 space-y-0.5">
                    <li>Reminders check daily at 7 AM based on your company's pay schedule.</li>
                    <li><strong>Create Payroll</strong> — sent when it's time to start the next pay period but one hasn't been created yet.</li>
                    <li><strong>Upcoming</strong> — sent when a pay period exists but hasn't been committed, and the pay date is approaching.</li>
                    <li><strong>Overdue</strong> — sent if payroll is still not committed after the pay date.</li>
                    <li>Each reminder type is sent once per pay period — no duplicate emails.</li>
                  </ul>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Action buttons */}
        <div className="flex flex-wrap items-center gap-3">
          <Button onClick={handleSave} disabled={saving || !hasChanges}>
            {saving ? 'Saving...' : 'Save Settings'}
          </Button>

          {config?.enabled && recipients.length > 0 && (
            <Button variant="outline" onClick={handleSendTest} disabled={testing}>
              <Send className="mr-1.5 h-4 w-4" />
              {testing ? 'Sending...' : 'Send Test Email'}
            </Button>
          )}

          <Button
            variant="outline"
            onClick={() => {
              setShowLogs(!showLogs);
              if (!showLogs) loadLogs();
            }}
          >
            <History className="mr-1.5 h-4 w-4" />
            {showLogs ? 'Hide Log' : 'View Sent Log'}
          </Button>
        </div>

        {/* Sent logs section */}
        {showLogs && (
          <Card>
            <CardContent className="p-6">
              <h3 className="mb-4 text-base font-semibold text-neutral-900">Reminder Log</h3>

              {logsLoading ? (
                <div className="flex justify-center py-8">
                  <div className="h-6 w-6 animate-spin rounded-full border-2 border-blue-600 border-t-transparent" />
                </div>
              ) : logs.length === 0 ? (
                <p className="py-8 text-center text-sm text-neutral-400">
                  No reminders have been sent yet.
                </p>
              ) : (
                <div className="overflow-x-auto">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Type</TableHead>
                        <TableHead>Pay Period</TableHead>
                        <TableHead>Pay Date</TableHead>
                        <TableHead>Sent At</TableHead>
                        <TableHead>Recipients</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {logs.map((log) => {
                        const typeLabel =
                          log.reminder_type === 'overdue' ? 'Overdue' :
                          log.reminder_type === 'create_payroll' ? 'Create Payroll' :
                          'Upcoming';
                        const typeVariant =
                          log.reminder_type === 'overdue' ? 'destructive' as const :
                          log.reminder_type === 'create_payroll' ? 'default' as const :
                          'secondary' as const;

                        return (
                          <TableRow key={log.id}>
                            <TableCell>
                              <Badge variant={typeVariant}>{typeLabel}</Badge>
                            </TableCell>
                            <TableCell className="text-sm">
                              {log.pay_period ? (
                                <>
                                  {new Date(log.pay_period.start_date).toLocaleDateString()} –{' '}
                                  {new Date(log.pay_period.end_date).toLocaleDateString()}
                                </>
                              ) : (
                                <span className="text-neutral-400 italic">Not yet created</span>
                              )}
                            </TableCell>
                            <TableCell className="text-sm">
                              {log.pay_period
                                ? new Date(log.pay_period.pay_date).toLocaleDateString()
                                : log.expected_pay_date
                                  ? new Date(log.expected_pay_date).toLocaleDateString()
                                  : '—'}
                            </TableCell>
                            <TableCell className="text-sm text-neutral-500">
                              {new Date(log.sent_at).toLocaleString()}
                            </TableCell>
                            <TableCell className="text-sm text-neutral-500">
                              {log.recipients_snapshot.join(', ')}
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>
              )}
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
