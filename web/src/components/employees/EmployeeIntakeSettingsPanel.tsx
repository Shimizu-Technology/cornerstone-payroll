import { useRef, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { useEmployeeIntakeSettings } from '@/hooks/useEmployeeIntakeSettings';
import { employeeIntakeApi } from '@/services/employee-intake-api';
import { formatGuamDateTime } from '@/lib/utils';

export function EmployeeIntakeSettingsPanel({ companyId, isClient, readOnly = false }: { companyId: number; isClient: boolean; readOnly?: boolean }) {
  const { settings, loading, error, reload } = useEmployeeIntakeSettings(companyId, isClient);
  const [reason, setReason] = useState('');
  const [hours, setHours] = useState('1');
  const [expanded, setExpanded] = useState(false);
  const [savingScope, setSavingScope] = useState<number | null>(null);
  const [feedback, setFeedback] = useState<{ companyId: number; error?: string; success?: string } | null>(null);
  const companyRef = useRef(companyId);
  companyRef.current = companyId;
  const saving = savingScope === companyId;

  const save = async (enabled: boolean) => {
    const requestedCompany = companyId;
    setSavingScope(requestedCompany);
    setFeedback(null);
    try {
      await employeeIntakeApi.updateSettings(requestedCompany, {
        enabled,
        ...(enabled ? { reason: reason.trim(), expires_at: new Date(Date.now() + Number(hours) * 3_600_000).toISOString() } : {}),
      });
      if (companyRef.current !== requestedCompany) return;
      setReason('');
      await reload();
      if (companyRef.current !== requestedCompany) return;
      setFeedback({ companyId: requestedCompany, success: enabled ? 'Incomplete employee entry enabled for this client.' : 'Full details are required for new employee entries again.' });
    } catch (caught) {
      if (companyRef.current === requestedCompany) setFeedback({ companyId: requestedCompany, error: caught instanceof Error ? caught.message : 'Could not update entry settings.' });
    } finally {
      setSavingScope((current) => current === requestedCompany ? null : current);
    }
  };

  if (loading && !settings) return <p className="mb-4 text-sm text-neutral-500">Loading employee entry settings…</p>;
  if (error) return <div className="mb-4"><ActionFeedback tone="error" message={`Employee entry settings unavailable. Full details remain required. ${error}`} /><Button variant="outline" onClick={() => void reload()}>Retry entry settings</Button></div>;
  if (!settings) return null;

  return (
    <section className="mb-6 rounded-xl border border-neutral-200 bg-white p-4" aria-label="Employee entry requirements">
      <p className="font-semibold text-neutral-900">{settings.enabled ? 'Incomplete employee entry is temporarily enabled' : 'Full employee details required'}</p>
      <p className="mt-1 text-sm leading-6 text-neutral-600">{settings.enabled
        ? `Enabled by ${settings.enabled_by_name || 'an administrator'} until ${formatGuamDateTime(settings.expires_at || '')}. ${settings.reason || ''}`
        : 'An administrator can temporarily allow missing personal details for this client.'}</p>
      {settings.enabled && <p className="mt-2 text-sm text-warning-800">Missing information stays on the employee checklist. Payroll documents and filing requirements still apply.</p>}
      {settings.can_manage && !readOnly && (
        settings.enabled ? <Button className="mt-3" variant="outline" disabled={saving} onClick={() => void save(false)}>Require full details again</Button>
          : <div className="mt-3">
            <Button variant="outline" aria-expanded={expanded} onClick={() => setExpanded((current) => !current)}>Allow incomplete entry temporarily</Button>
            {expanded && <div className="mt-3 grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-end">
              <label className="text-sm font-medium text-neutral-700">Reason
                <Input value={reason} maxLength={500} onChange={(event) => setReason(event.target.value)} placeholder="Employer has not provided the remaining information" />
              </label>
              <label className="text-sm font-medium text-neutral-700">Automatically require full details after
                <Select value={hours} onChange={(event) => setHours(event.target.value)}><option value="1">1 hour</option><option value="4">4 hours</option><option value="24">24 hours</option></Select>
              </label>
              <Button disabled={saving || !reason.trim()} onClick={() => void save(true)}>{saving ? 'Enabling…' : 'Enable incomplete entry'}</Button>
            </div>}
          </div>
      )}
      {feedback?.companyId === companyId && feedback.error && <ActionFeedback tone="error" message={feedback.error} />}
      {feedback?.companyId === companyId && feedback.success && <ActionFeedback tone="success" message={feedback.success} />}
    </section>
  );
}
