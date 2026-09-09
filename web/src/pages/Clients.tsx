import { useState, useEffect, useCallback, useId, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { Plus, Building2, Check, X, Pencil, FlaskConical, ShieldCheck, AlertTriangle, ArrowRight } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { companiesApi, ApiError } from '@/services/api';
import type { CompanyListItem, CompanyFormData, MigrationRehearsalPreview } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';
import { useAuth } from '@/contexts/AuthContext';

const payFrequencyOptions = [
  { value: 'biweekly', label: 'Biweekly' },
  { value: 'weekly', label: 'Weekly' },
  { value: 'semimonthly', label: 'Semi-monthly' },
  { value: 'monthly', label: 'Monthly' },
];

const checkStockOptions = [
  { value: 'top_check', label: 'Top Check' },
  { value: 'bottom_check', label: 'Bottom Check' },
  { value: 'first_hawaiian_4up', label: 'First Hawaiian 4-Up' },
];

const emptyForm: CompanyFormData = {
  name: '',
  ein: '',
  pay_frequency: 'biweekly',
  address_line1: '',
  address_line2: '',
  city: '',
  state: '',
  zip: '',
  phone: '',
  email: '',
  bank_name: '',
  bank_address: '',
  check_stock_type: 'top_check',
  next_check_number: 1001,
  simple_payroll_register_enabled: false,
  historical_payroll_enabled: false,
};

function formatEIN(value: string): string {
  const digits = value.replace(/\D/g, '').slice(0, 9);
  if (digits.length <= 2) return digits;
  return `${digits.slice(0, 2)}-${digits.slice(2)}`;
}

function formatBytes(value = 0): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

interface SettingToggleProps {
  checked: boolean;
  label: string;
  description?: string;
  onToggle: () => void;
}

function SettingToggle({ checked, label, description, onToggle }: SettingToggleProps): ReactElement {
  const switchId = useId();
  const labelId = `${switchId}-label`;
  const descriptionId = description ? `${switchId}-description` : undefined;

  return (
    <div className="flex items-start gap-4 rounded-lg border border-gray-200 bg-gray-50 p-4">
      <button
        id={switchId}
        type="button"
        role="switch"
        aria-checked={checked}
        aria-labelledby={labelId}
        aria-describedby={descriptionId}
        onClick={onToggle}
        className={`relative mt-0.5 inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 ${
          checked ? 'bg-blue-600' : 'bg-gray-300'
        }`}
      >
        <span
          className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
            checked ? 'translate-x-6' : 'translate-x-1'
          }`}
        />
      </button>
      <div>
        <label id={labelId} htmlFor={switchId} className="cursor-pointer text-sm font-medium text-gray-800">{label}</label>
        {description && <p id={descriptionId} className="mt-1 text-xs leading-5 text-gray-600">{description}</p>}
      </div>
    </div>
  );
}

export function Clients() {
  const navigate = useNavigate();
  const { refreshCompanies, switchCompany } = useCompany();
  const { isAdmin: canManageClients, isAccountant, isManager } = useAuth();
  const canEditAssignedClients = canManageClients || isAccountant || isManager;
  const [companies, setCompanies] = useState<CompanyListItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [form, setForm] = useState<CompanyFormData>({ ...emptyForm });
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [loadingEditId, setLoadingEditId] = useState<number | null>(null);
  const [rehearsalSourceId, setRehearsalSourceId] = useState<number | null>(null);
  const [rehearsalPreview, setRehearsalPreview] = useState<MigrationRehearsalPreview | null>(null);
  const [rehearsalName, setRehearsalName] = useState('');
  const [loadingRehearsal, setLoadingRehearsal] = useState(false);
  const [creatingRehearsal, setCreatingRehearsal] = useState(false);
  const [rehearsalConfirmed, setRehearsalConfirmed] = useState(false);
  const [rehearsalError, setRehearsalError] = useState<string | null>(null);
  const [retryingRehearsalId, setRetryingRehearsalId] = useState<number | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await companiesApi.list();
      setCompanies(data.companies);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load clients');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  useEffect(() => {
    if (!companies.some(company => company.migration_rehearsal_status === 'pending')) return;
    const timer = window.setTimeout(() => { void load(); }, 3000);
    return () => window.clearTimeout(timer);
  }, [companies, load]);

  const handleOpenRehearsal = async (company: CompanyListItem) => {
    setRehearsalSourceId(company.id);
    setRehearsalPreview(null);
    setRehearsalName(`${company.name} Migration Test`);
    setRehearsalConfirmed(false);
    setRehearsalError(null);
    setLoadingRehearsal(true);
    try {
      const response = await companiesApi.migrationRehearsalPreview(company.id);
      setRehearsalPreview(response.migration_rehearsal);
    } catch (err) {
      setRehearsalError(err instanceof Error ? err.message : 'Could not prepare the rehearsal preview');
    } finally {
      setLoadingRehearsal(false);
    }
  };

  const handleCloseRehearsal = () => {
    setRehearsalSourceId(null);
    setRehearsalPreview(null);
    setRehearsalConfirmed(false);
    setRehearsalError(null);
  };

  const handleCreateRehearsal = async () => {
    if (!rehearsalSourceId || !rehearsalPreview?.historical_import_batch_id || !rehearsalConfirmed) return;
    setCreatingRehearsal(true);
    setRehearsalError(null);
    try {
      await companiesApi.createMigrationRehearsal(rehearsalSourceId, {
        name: rehearsalName.trim(),
        historical_import_batch_id: rehearsalPreview.historical_import_batch_id,
        acknowledgement: 'CREATE MIGRATION REHEARSAL',
      });
      handleCloseRehearsal();
      await load();
      await refreshCompanies();
    } catch (err) {
      setRehearsalError(err instanceof Error ? err.message : 'Could not create the migration rehearsal');
    } finally {
      setCreatingRehearsal(false);
    }
  };

  const handleRetryRehearsal = async (companyId: number) => {
    setRetryingRehearsalId(companyId);
    setError(null);
    try {
      await companiesApi.retryMigrationRehearsal(companyId);
      await load();
      await refreshCompanies();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not retry the migration rehearsal');
    } finally {
      setRetryingRehearsalId(null);
    }
  };

  const handleOpenReadyRehearsal = (companyId: number) => {
    switchCompany(companyId);
    navigate(`/companies/${companyId}/pay-runs`);
  };

  const handleAddNew = () => {
    setEditingId(null);
    setForm({ ...emptyForm });
    setFormError(null);
    setShowForm(true);
  };

  const handleEdit = async (id: number) => {
    setLoadingEditId(id);
    try {
      const data = await companiesApi.get(id);
      const c = data.company;
      setForm({
        name: c.name || '',
        ein: c.ein || '',
        pay_frequency: c.pay_frequency || 'biweekly',
        active: c.active,
        address_line1: c.address_line1 || '',
        address_line2: c.address_line2 || '',
        city: c.city || '',
        state: c.state || '',
        zip: c.zip || '',
        phone: c.phone || '',
        email: c.email || '',
        bank_name: c.bank_name || '',
        bank_address: c.bank_address || '',
        check_stock_type: c.check_stock_type || 'bottom_check',
        next_check_number: c.next_check_number ?? 1001,
        simple_payroll_register_enabled: c.simple_payroll_register_enabled === true,
        historical_payroll_enabled: c.historical_payroll_enabled === true,
      });
      setEditingId(id);
      setFormError(null);
      setShowForm(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load client details');
    } finally {
      setLoadingEditId(null);
    }
  };

  const handleCancel = () => {
    setShowForm(false);
    setEditingId(null);
    setForm({ ...emptyForm });
    setFormError(null);
  };

  const handleSave = async () => {
    if (canManageClients && !form.name.trim()) {
      setFormError('Client name is required');
      return;
    }

    setSaving(true);
    setFormError(null);

    try {
      if (editingId) {
        await companiesApi.update(editingId, form);
      } else {
        await companiesApi.create(form);
      }
      setShowForm(false);
      setEditingId(null);
      setForm({ ...emptyForm });
      await load();
      refreshCompanies();
    } catch (err) {
      if (err instanceof ApiError) {
        setFormError(err.message);
      } else {
        setFormError(err instanceof Error ? err.message : 'Failed to save');
      }
    } finally {
      setSaving(false);
    }
  };

  const updateField = (field: keyof CompanyFormData, value: string | number | boolean) => {
    setForm(prev => ({ ...prev, [field]: value }));
  };

  return (
    <>
      <Header
        title={canManageClients ? 'Client Management' : 'Client Info'}
        subtitle={canManageClients ? 'Manage payroll clients' : 'View and update assigned client contact details'}
      />

      <div className="space-y-6 p-4 sm:p-6">
        {/* Error */}
        {error && (
          <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
            {error}
          </div>
        )}

        {/* Add new button */}
        {canManageClients && !showForm && (
          <div className="flex justify-end">
            <Button onClick={handleAddNew}>
              <Plus className="w-4 h-4 mr-2" />
              Add New Client
            </Button>
          </div>
        )}

        {rehearsalSourceId && (
          <Card className="border-amber-200 p-5 sm:p-6">
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-start gap-3">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-amber-100 text-amber-800">
                  <FlaskConical className="h-5 w-5" />
                </div>
                <div>
                  <h3 className="font-semibold text-neutral-950">Create a migration rehearsal</h3>
                  <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-600">
                    Make a verified working copy of the imported payroll and employee setup. Cornerstone can review, edit setup, and calculate practice payroll here without changing the clean migration client.
                  </p>
                </div>
              </div>
              <Button variant="ghost" size="sm" onClick={handleCloseRehearsal} aria-label="Close migration rehearsal setup">
                <X className="h-4 w-4" />
              </Button>
            </div>

            {loadingRehearsal ? (
              <p className="mt-5 text-sm text-neutral-500">Checking the source archive…</p>
            ) : rehearsalPreview && (
              <div className="mt-5 space-y-4">
                <div className="grid gap-3 sm:grid-cols-4">
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Employees</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.employees ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Imported pay periods</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.imported_pay_periods ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Imported paychecks</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.imported_paychecks ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Source evidence</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.retained_source_files ?? 0} files · {formatBytes(rehearsalPreview.copy_summary.source_file_bytes)}</p></div>
                </div>

                <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">
                  <p className="font-semibold text-neutral-900">Copy boundaries</p>
                  <ul className="mt-2 list-disc space-y-1 pl-5">{rehearsalPreview.warnings.map(item => <li key={item}>{item}</li>)}</ul>
                </div>

                {rehearsalPreview.blockers.length > 0 && (
                  <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
                    <div className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Not ready to copy</div>
                    <ul className="mt-2 list-disc space-y-1 pl-5">{rehearsalPreview.blockers.map(item => <li key={item}>{item}</li>)}</ul>
                  </div>
                )}

                {rehearsalPreview.ready && (
                  <>
                    <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
                      <div className="flex items-center gap-2 font-semibold"><ShieldCheck className="h-4 w-4" />Built-in safety</div>
                      <p className="mt-1 leading-6">The original remains untouched. Practice runs are always parallel-only and cannot be committed. Check, payment, and official filing actions are blocked.</p>
                    </div>
                    <div className="max-w-xl">
                      <label className="mb-1 block text-sm font-medium text-neutral-700">Rehearsal name</label>
                      <Input value={rehearsalName} onChange={event => setRehearsalName(event.target.value)} />
                    </div>
                    <label className="flex cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-4 text-sm text-neutral-700">
                      <input type="checkbox" checked={rehearsalConfirmed} onChange={event => setRehearsalConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 rounded border-neutral-300" />
                      <span>I understand this copy contains protected payroll and employee data and must only be used inside Cornerstone for migration testing.</span>
                    </label>
                  </>
                )}
              </div>
            )}

            {rehearsalError && <div className="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-700">{rehearsalError}</div>}
            <div className="mt-5 flex justify-end gap-3 border-t border-neutral-200 pt-4">
              <Button variant="outline" onClick={handleCloseRehearsal}>Cancel</Button>
              <Button onClick={handleCreateRehearsal} disabled={!rehearsalPreview?.ready || !rehearsalConfirmed || !rehearsalName.trim() || creatingRehearsal}>
                <FlaskConical className="mr-2 h-4 w-4" />{creatingRehearsal ? 'Creating verified copy…' : 'Create migration test'}
              </Button>
            </div>
          </Card>
        )}

        {/* Create / Edit form */}
        {showForm && (
          <Card className="p-6">
            <h3 className="text-lg font-semibold mb-4">
              {editingId ? 'Edit Client' : 'New Client'}
            </h3>

            {formError && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
                {formError}
              </div>
            )}

            {/* Basic Info */}
            <div className="space-y-4">
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1">Basic Information</h4>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Client Name <span className="text-red-500">*</span>
                  </label>
                  <Input
                    value={form.name}
                    onChange={(e) => updateField('name', e.target.value)}
                    placeholder="e.g. MoSa's Hotbox, Inc."
                    disabled={!canManageClients}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">EIN</label>
                  <Input
                    value={form.ein || ''}
                    onChange={(e) => updateField('ein', formatEIN(e.target.value))}
                    placeholder="XX-XXXXXXX"
                    disabled={!canManageClients}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Pay Frequency</label>
                  <Select
                    value={form.pay_frequency}
                    onChange={(e) => updateField('pay_frequency', e.target.value)}
                    disabled={!canManageClients}
                  >
                    {payFrequencyOptions.map(opt => (
                      <option key={opt.value} value={opt.value}>{opt.label}</option>
                    ))}
                  </Select>
                </div>
              </div>

              {/* Contact */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Contact</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Phone</label>
                  <Input
                    value={form.phone || ''}
                    onChange={(e) => updateField('phone', e.target.value)}
                    placeholder="(671) 555-1234"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Email</label>
                  <Input
                    type="email"
                    value={form.email || ''}
                    onChange={(e) => updateField('email', e.target.value)}
                    placeholder="payroll@company.com"
                  />
                </div>
              </div>

              {/* Address */}
              <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Address</h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Address Line 1</label>
                  <Input
                    value={form.address_line1 || ''}
                    onChange={(e) => updateField('address_line1', e.target.value)}
                    placeholder="123 Main St"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">Address Line 2</label>
                  <Input
                    value={form.address_line2 || ''}
                    onChange={(e) => updateField('address_line2', e.target.value)}
                    placeholder="Suite 100"
                  />
                </div>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">City</label>
                  <Input
                    value={form.city || ''}
                    onChange={(e) => updateField('city', e.target.value)}
                    placeholder="Tamuning"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">State</label>
                  <Input
                    value={form.state || ''}
                    onChange={(e) => updateField('state', e.target.value)}
                    placeholder="GU"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">ZIP</label>
                  <Input
                    value={form.zip || ''}
                    onChange={(e) => updateField('zip', e.target.value)}
                    placeholder="96913"
                  />
                </div>
              </div>

              {canManageClients && (
                <>
                  {/* Bank Info */}
                  <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Bank Information</h4>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-700 mb-1">Bank Name</label>
                      <Input
                        value={form.bank_name || ''}
                        onChange={(e) => updateField('bank_name', e.target.value)}
                        placeholder="Bank of Guam"
                      />
                    </div>
                    <div>
                      <label className="block text-sm font-medium text-gray-700 mb-1">Bank Address</label>
                      <Input
                        value={form.bank_address || ''}
                        onChange={(e) => updateField('bank_address', e.target.value)}
                        placeholder="111 Chalan Santo Papa"
                      />
                    </div>
                  </div>

                  {/* Payroll Reporting */}
                  <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Payroll Reporting</h4>
                  <SettingToggle
                    checked={form.simple_payroll_register_enabled === true}
                    label="Simple payroll register Excel format"
                    description="Adds the SCR/AIRE register as the first worksheet while preserving the detailed payroll sheets. Leave this off for clients that require a different register format."
                    onToggle={() => updateField('simple_payroll_register_enabled', form.simple_payroll_register_enabled !== true)}
                  />

                  <SettingToggle
                    checked={form.historical_payroll_enabled === true}
                    label="Historical payroll workspace"
                    description="Opens the protected QuickBooks migration workspace for this client. Keep this off until the source bundle is ready for review."
                    onToggle={() => updateField('historical_payroll_enabled', form.historical_payroll_enabled !== true)}
                  />

                  {/* Check Settings */}
                  <h4 className="text-sm font-medium text-gray-700 border-b pb-1 pt-2">Check Settings</h4>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-medium text-gray-700 mb-1">Check Stock Type</label>
                      <Select
                        value={form.check_stock_type || 'bottom_check'}
                        onChange={(e) => updateField('check_stock_type', e.target.value)}
                      >
                        {checkStockOptions.map(opt => (
                          <option key={opt.value} value={opt.value}>{opt.label}</option>
                        ))}
                      </Select>
                    </div>
                    <div>
                      <label className="block text-sm font-medium text-gray-700 mb-1">Next Check Number</label>
                      <NumericInput
                        value={form.next_check_number ?? 1001}
                        onValueChange={(value) => updateField('next_check_number', Math.max(1, Math.round(value ?? 1001)))}
                        min={1}
                        fixedDecimalsOnBlur={0}
                      />
                    </div>
                  </div>
                </>
              )}

              {/* Active toggle (edit only) */}
              {editingId && canManageClients && (
                <SettingToggle
                  checked={form.active !== false}
                  label="Active client"
                  onToggle={() => updateField('active', form.active === false)}
                />
              )}
            </div>

            {/* Actions */}
            <div className="flex justify-end gap-3 mt-6 pt-4 border-t">
              <Button variant="outline" onClick={handleCancel} disabled={saving}>
                <X className="w-4 h-4 mr-1" /> Cancel
              </Button>
              <Button onClick={handleSave} disabled={saving}>
                <Check className="w-4 h-4 mr-1" />
                {saving ? 'Saving…' : editingId ? 'Update Client' : 'Create Client'}
              </Button>
            </div>
          </Card>
        )}

        {/* Clients list */}
        {loading ? (
          <div className="flex items-center justify-center py-12 text-gray-500">Loading clients…</div>
        ) : (
          <>
            <div className="space-y-3 sm:hidden">
              {companies.length === 0 ? (
                <MobileRecordCard className="text-center text-sm text-neutral-500">
                  {canManageClients ? 'No clients found. Add a new client to get started.' : 'No assigned clients found.'}
                </MobileRecordCard>
              ) : companies.map((c) => (
                <MobileRecordCard key={c.id}>
                  <div className="flex items-start gap-3">
                    <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
                      <Building2 className="h-5 w-5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-neutral-950">{c.name}</p>
                          {c.payroll_environment === 'migration_rehearsal' && (
                            <p className="mt-0.5 text-xs font-semibold text-amber-700">Migration rehearsal · {c.migration_rehearsal_status}</p>
                          )}
                        </div>
                        <Badge variant={c.migration_rehearsal_status === 'failed' ? 'danger' : c.active !== false ? 'success' : 'default'}>
                          {c.migration_rehearsal_status === 'pending'
                            ? 'Preparing'
                            : c.migration_rehearsal_status === 'failed'
                              ? 'Needs attention'
                              : c.payroll_environment === 'migration_rehearsal'
                                ? 'Ready to test'
                                : c.active !== false ? 'Active' : 'Inactive'}
                        </Badge>
                      </div>
                      <div className="mt-4 grid grid-cols-2 gap-3">
                        <MobileField label="Pay frequency" value={<span className="capitalize">{c.pay_frequency}</span>} />
                        <MobileField label="Employees" value={`${c.active_employees} / ${c.total_employees}`} />
                      </div>
                      {canEditAssignedClients && (
                        <MobileCardActions>
                          {c.payroll_environment === 'migration_rehearsal' && c.migration_rehearsal_status === 'ready' && (
                            <Button size="sm" onClick={() => handleOpenReadyRehearsal(c.id)}>
                              Open test <ArrowRight className="ml-1 h-4 w-4" />
                            </Button>
                          )}
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => handleEdit(c.id)}
                            disabled={loadingEditId === c.id || c.migration_rehearsal_status === 'pending'}
                          >
                            <Pencil className="mr-1 h-4 w-4" />
                            {loadingEditId === c.id ? 'Loading...' : 'Edit'}
                          </Button>
                          {canManageClients && c.payroll_environment === 'live' && (
                            <Button size="sm" variant="outline" onClick={() => handleOpenRehearsal(c)}>
                              <FlaskConical className="mr-1 h-4 w-4" />Migration test
                            </Button>
                          )}
                          {canManageClients && c.migration_rehearsal_status === 'failed' && (
                            <Button size="sm" variant="outline" onClick={() => handleRetryRehearsal(c.id)} disabled={retryingRehearsalId === c.id}>
                              {retryingRehearsalId === c.id ? 'Retrying…' : 'Retry copy'}
                            </Button>
                          )}
                        </MobileCardActions>
                      )}
                    </div>
                  </div>
                </MobileRecordCard>
              ))}
            </div>
            <Card className="hidden sm:block">
              <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Client Name</TableHead>
                  <TableHead>EIN</TableHead>
                  <TableHead>Pay Frequency</TableHead>
                  <TableHead className="text-center">Employees</TableHead>
                  <TableHead className="text-center">Status</TableHead>
                  {canEditAssignedClients && <TableHead className="text-right">Actions</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {companies.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={canEditAssignedClients ? 6 : 5} className="text-center py-8 text-gray-500">
                      {canManageClients ? 'No clients found. Click "Add New Client" to get started.' : 'No assigned clients found.'}
                    </TableCell>
                  </TableRow>
                ) : (
                  companies.map((c) => (
                    <TableRow key={c.id}>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          {c.payroll_environment === 'migration_rehearsal' ? <FlaskConical className="h-4 w-4 text-amber-700" /> : <Building2 className="w-4 h-4 text-gray-400" />}
                          <div>
                            <span className="font-medium text-gray-900">{c.name}</span>
                            {c.payroll_environment === 'migration_rehearsal' && (
                              <p className="text-xs font-medium text-amber-700">Migration rehearsal · source: {c.migration_source_company_name || 'linked client'}</p>
                            )}
                            {c.migration_rehearsal_status === 'failed' && c.migration_rehearsal_error && (
                              <p className="mt-1 max-w-md text-xs text-red-700">{c.migration_rehearsal_error}</p>
                            )}
                          </div>
                        </div>
                      </TableCell>
                      <TableCell className="text-gray-600 font-mono text-sm">—</TableCell>
                      <TableCell className="text-gray-600 capitalize">{c.pay_frequency}</TableCell>
                      <TableCell className="text-center">
                        <span className="text-gray-900 font-medium">{c.active_employees}</span>
                        <span className="text-gray-400 text-xs ml-1">/ {c.total_employees}</span>
                      </TableCell>
                      <TableCell className="text-center">
                        {c.migration_rehearsal_status === 'pending' ? (
                          <Badge variant="info">Preparing</Badge>
                        ) : c.migration_rehearsal_status === 'failed' ? (
                          <Badge variant="danger">Needs attention</Badge>
                        ) : c.active !== false ? (
                          <Badge variant="success">{c.payroll_environment === 'migration_rehearsal' ? 'Ready to test' : 'Active'}</Badge>
                        ) : (
                          <Badge variant="default">Inactive</Badge>
                        )}
                      </TableCell>
                      {canEditAssignedClients && (
                        <TableCell className="text-right">
                          <div className="flex justify-end gap-2">
                            {c.payroll_environment === 'migration_rehearsal' && c.migration_rehearsal_status === 'ready' && (
                              <Button size="sm" onClick={() => handleOpenReadyRehearsal(c.id)} className="text-xs">
                                Open test <ArrowRight className="ml-1 h-3.5 w-3.5" />
                              </Button>
                            )}
                            {canManageClients && c.payroll_environment === 'live' && (
                              <Button size="sm" variant="outline" onClick={() => handleOpenRehearsal(c)} className="text-xs">
                                <FlaskConical className="mr-1 h-3.5 w-3.5" />Migration test
                              </Button>
                            )}
                            {canManageClients && c.migration_rehearsal_status === 'failed' && (
                              <Button size="sm" variant="outline" onClick={() => handleRetryRehearsal(c.id)} disabled={retryingRehearsalId === c.id} className="text-xs">
                                {retryingRehearsalId === c.id ? 'Retrying…' : 'Retry copy'}
                              </Button>
                            )}
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={() => handleEdit(c.id)}
                              className="text-xs"
                              disabled={loadingEditId === c.id || c.migration_rehearsal_status === 'pending'}
                            >
                              {loadingEditId === c.id ? (
                                <>
                                  <div className="w-3 h-3 mr-1 animate-spin rounded-full border-2 border-gray-300 border-t-gray-600" />
                                  Loading...
                                </>
                              ) : (
                                <><Pencil className="w-3 h-3 mr-1" /> Edit</>
                              )}
                            </Button>
                          </div>
                        </TableCell>
                      )}
                    </TableRow>
                  ))
                )}
              </TableBody>
              </Table>
            </Card>
          </>
        )}
      </div>
    </>
  );
}
