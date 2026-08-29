import { useCallback, useEffect, useState } from 'react';
import { FileSpreadsheet, Save } from 'lucide-react';
import { SettingsSection } from '@/components/settings/SettingsSection';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { useCompany } from '@/contexts/CompanyContext';
import { companiesApi, type CompanyDetail } from '@/services/api';

export function ClientReportSettings() {
  const { activeCompanyId } = useCompany();
  const [company, setCompany] = useState<CompanyDetail | null>(null);
  const [enabled, setEnabled] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!activeCompanyId) {
      setCompany(null);
      setError('Select a client to review its report settings.');
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const response = await companiesApi.get(activeCompanyId);
      setCompany(response.company);
      setEnabled(response.company.simple_payroll_register_enabled === true);
    } catch (err) {
      setCompany(null);
      setError(err instanceof Error ? err.message : 'Failed to load report settings');
    } finally {
      setLoading(false);
    }
  }, [activeCompanyId]);

  useEffect(() => { void load(); }, [load]);

  const canEdit = company?.editable_fields?.includes('simple_payroll_register_enabled') === true;
  const hasChanges = company != null && enabled !== (company.simple_payroll_register_enabled === true);

  const save = async () => {
    if (!activeCompanyId || !canEdit) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await companiesApi.update(activeCompanyId, { simple_payroll_register_enabled: enabled });
      setCompany(response.company);
      setSuccess('Report settings saved for this client.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save report settings');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return <div className="rounded-[1.35rem] border border-neutral-200 bg-white p-10 text-center text-sm text-neutral-500">Loading report settings…</div>;
  }

  if (!company) {
    return <div role="alert" className="rounded-[1.35rem] border border-danger-200 bg-danger-50 p-10 text-center text-sm text-danger-800">{error || 'Report settings are unavailable.'}</div>;
  }

  return (
    <SettingsSection
      title="Reports & exports"
      description="Client-specific output preferences. These choices change report presentation, not payroll calculations."
      actions={<Button onClick={save} disabled={!canEdit || !hasChanges || saving}><Save className="mr-2 h-4 w-4" />{saving ? 'Saving…' : 'Save report settings'}</Button>}
    >
      {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">{error}</div>}
      {success && <div role="status" className="rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-800">{success}</div>}

      <Card>
        <CardContent className="py-6">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
            <div className="flex items-start gap-3">
              <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><FileSpreadsheet className="h-5 w-5" /></div>
              <div>
                <h3 className="font-semibold text-neutral-950">Simple payroll register Excel format</h3>
                <p className="mt-1 max-w-2xl text-sm leading-6 text-neutral-500">Adds the SCR/AIRE register as the first worksheet while preserving the detailed payroll sheets. Leave this off for clients that require the standard detailed workbook.</p>
                {!canEdit && <p className="mt-2 text-xs font-semibold text-warning-800">A manager or firm administrator must change this setting.</p>}
              </div>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={enabled}
              aria-label="Use simple payroll register Excel format"
              disabled={!canEdit}
              onClick={() => { setEnabled((current) => !current); setSuccess(null); }}
              className={`relative inline-flex h-7 w-12 shrink-0 items-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 disabled:cursor-not-allowed disabled:opacity-50 ${enabled ? 'bg-primary-700' : 'bg-neutral-300'}`}
            >
              <span className={`inline-block h-5 w-5 rounded-full bg-white shadow-sm transition-transform ${enabled ? 'translate-x-6' : 'translate-x-1'}`} />
            </button>
          </div>
        </CardContent>
      </Card>
    </SettingsSection>
  );
}
