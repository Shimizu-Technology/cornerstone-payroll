import { useCallback, useEffect, useMemo, useState } from 'react';
import { Building2, Save, ShieldCheck } from 'lucide-react';
import { SettingsSection } from '@/components/settings/SettingsSection';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { useCompany } from '@/contexts/CompanyContext';
import { ApiError, companiesApi, type CompanyDetail } from '@/services/api';

type ProfileForm = Pick<CompanyDetail, 'name' | 'ein' | 'address_line1' | 'address_line2' | 'city' | 'state' | 'zip' | 'phone' | 'email'>;

function buildForm(company: CompanyDetail): ProfileForm {
  return {
    name: company.name || '',
    ein: company.ein || '',
    address_line1: company.address_line1 || '',
    address_line2: company.address_line2 || '',
    city: company.city || '',
    state: company.state || '',
    zip: company.zip || '',
    phone: company.phone || '',
    email: company.email || '',
  };
}

function formatEin(value: string) {
  const digits = value.replace(/\D/g, '').slice(0, 9);
  return digits.length <= 2 ? digits : `${digits.slice(0, 2)}-${digits.slice(2)}`;
}

export function ClientCompanyProfile() {
  const { activeCompanyId, refreshCompanies } = useCompany();
  const [company, setCompany] = useState<CompanyDetail | null>(null);
  const [form, setForm] = useState<ProfileForm | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!activeCompanyId) {
      setCompany(null);
      setForm(null);
      setError('Select a client to review its company profile.');
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const response = await companiesApi.get(activeCompanyId);
      setCompany(response.company);
      setForm(buildForm(response.company));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load company profile');
    } finally {
      setLoading(false);
    }
  }, [activeCompanyId]);

  useEffect(() => { void load(); }, [load]);

  const editableFields = useMemo(() => new Set(company?.editable_fields || []), [company?.editable_fields]);
  const hasChanges = company != null && form != null && JSON.stringify(form) !== JSON.stringify(buildForm(company));
  const canEdit = (field: keyof ProfileForm) => editableFields.has(field);

  useEffect(() => {
    if (!hasChanges) return;
    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = '';
    };
    window.addEventListener('beforeunload', beforeUnload);
    return () => window.removeEventListener('beforeunload', beforeUnload);
  }, [hasChanges]);

  const update = (field: keyof ProfileForm, value: string) => {
    setForm((current) => current ? { ...current, [field]: value } : current);
    setSuccess(null);
  };

  const save = async () => {
    if (!activeCompanyId || !form) return;
    if (canEdit('name') && !form.name.trim()) {
      setError('Client name is required.');
      return;
    }

    const payload = Object.fromEntries(
      Object.entries(form).filter(([field]) => editableFields.has(field)),
    ) as Partial<ProfileForm>;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await companiesApi.update(activeCompanyId, payload);
      setCompany(response.company);
      setForm(buildForm(response.company));
      await refreshCompanies();
      setSuccess('Company profile saved for this client.');
    } catch (err) {
      setError(err instanceof ApiError ? err.message : err instanceof Error ? err.message : 'Failed to save company profile');
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return <div className="rounded-[1.35rem] border border-neutral-200 bg-white p-10 text-center text-sm text-neutral-500">Loading company profile…</div>;
  }

  if (!form || !company) {
    return <div role="alert" className="rounded-[1.35rem] border border-danger-200 bg-danger-50 p-10 text-center text-sm text-danger-800">{error || 'Company profile is unavailable.'}</div>;
  }

  return (
    <SettingsSection
      title="Company profile"
      description="Legal identity and contact information used throughout payroll reports, checks, and client communication."
      actions={<Button onClick={save} disabled={saving || !hasChanges}><Save className="mr-2 h-4 w-4" />{saving ? 'Saving…' : 'Save profile'}</Button>}
    >
      {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">{error}</div>}
      {success && <div role="status" className="rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-800">{success}</div>}
      {hasChanges && <div className="rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-900">You have unsaved company-profile changes.</div>}

      <Card>
        <CardContent className="space-y-6 py-6">
          <div className="flex items-start gap-3 border-b border-neutral-100 pb-5">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><Building2 className="h-5 w-5" /></div>
            <div>
              <h3 className="font-semibold text-neutral-950">Employer identity</h3>
              <p className="mt-1 text-sm leading-6 text-neutral-500">Name and EIN changes are limited to firm administrators. Contact fields remain available to assigned payroll staff.</p>
            </div>
          </div>

          <div className="grid gap-4 md:grid-cols-2">
            <Field label="Legal client name" value={form.name} onChange={(value) => update('name', value)} disabled={!canEdit('name')} />
            <Field label="Employer identification number" value={form.ein || ''} onChange={(value) => update('ein', formatEin(value))} disabled={!canEdit('ein')} placeholder="XX-XXXXXXX" />
            <Field label="Payroll contact email" value={form.email || ''} onChange={(value) => update('email', value)} disabled={!canEdit('email')} type="email" />
            <Field label="Payroll contact phone" value={form.phone || ''} onChange={(value) => update('phone', value)} disabled={!canEdit('phone')} />
          </div>

          <div className="border-t border-neutral-100 pt-5">
            <h3 className="font-semibold text-neutral-950">Mailing address</h3>
            <div className="mt-4 grid gap-4 md:grid-cols-2">
              <Field label="Address line 1" value={form.address_line1 || ''} onChange={(value) => update('address_line1', value)} disabled={!canEdit('address_line1')} />
              <Field label="Address line 2" value={form.address_line2 || ''} onChange={(value) => update('address_line2', value)} disabled={!canEdit('address_line2')} />
              <Field label="City" value={form.city || ''} onChange={(value) => update('city', value)} disabled={!canEdit('city')} />
              <div className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)] gap-4">
                <Field label="State" value={form.state || ''} onChange={(value) => update('state', value)} disabled={!canEdit('state')} />
                <Field label="ZIP code" value={form.zip || ''} onChange={(value) => update('zip', value)} disabled={!canEdit('zip')} />
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      <div className="flex items-start gap-3 rounded-2xl border border-primary-100 bg-primary-50/55 px-4 py-3 text-sm text-primary-950">
        <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" />
        <p>Payroll cadence, legal workweek, bank information, check stock, and check numbering are intentionally managed in their dedicated sections.</p>
      </div>
    </SettingsSection>
  );
}

function Field({ label, value, onChange, disabled, placeholder, type = 'text' }: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  disabled: boolean;
  placeholder?: string;
  type?: string;
}) {
  return (
    <label className="block text-sm font-semibold text-neutral-700">
      {label}
      <Input
        className="mt-1.5"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        disabled={disabled}
        placeholder={placeholder}
        type={type}
      />
    </label>
  );
}
