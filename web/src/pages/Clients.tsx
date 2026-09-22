import { Fragment, useState, useEffect, useCallback, useId, useRef, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { Plus, Building2, Check, X, Pencil, FlaskConical, ShieldCheck, AlertTriangle, ArrowRight, GraduationCap, RefreshCw } from 'lucide-react';
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
import { HelpTip } from '@/components/ui/help-tip';
import { TestWorkspaceGuide, WorkspaceRoleGuide } from '@/components/test-workspaces/TestWorkspaceGuides';
import { companiesApi, ApiError } from '@/services/api';
import type { CompanyListItem, CompanyFormData, MigrationPromotionPreview, MigrationRehearsalPreview, PromotionPaymentDisposition, TrainingReplayPreview } from '@/services/api';
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
  client_payroll_approval_required: false,
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

function formatShortDate(value: string): string {
  return new Date(`${value}T00:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatMoney(value: number | string): string {
  return Number(value).toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

const isTestWorkspace = (company: CompanyListItem): boolean =>
  company.test_workspace ?? company.payroll_environment === 'migration_rehearsal';

const testWorkspaceLabel = (company: CompanyListItem): string =>
  company.test_workspace_purpose_label || 'Test workspace';

const isReadOnlyWorkspace = (company: CompanyListItem): boolean =>
  company.test_workspace_purpose === 'backup_snapshot' || Boolean(company.test_workspace_sealed_at);

const testWorkspaceOpenLabel = (company: CompanyListItem): string => {
  if (company.test_workspace_purpose === 'backup_snapshot') return 'Open backup';
  if (company.test_workspace_sealed_at) return 'Open read-only';
  return 'Open test';
};

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
  const rehearsalNameId = useId();
  const trainingNameId = useId();
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
  const [workspaceBuilderOpen, setWorkspaceBuilderOpen] = useState(false);
  const [workspaceBuilderSourceId, setWorkspaceBuilderSourceId] = useState<number | null>(null);
  const [rehearsalSourceId, setRehearsalSourceId] = useState<number | null>(null);
  const [rehearsalPreview, setRehearsalPreview] = useState<MigrationRehearsalPreview | null>(null);
  const [rehearsalName, setRehearsalName] = useState('');
  const [loadingRehearsal, setLoadingRehearsal] = useState(false);
  const [creatingRehearsal, setCreatingRehearsal] = useState(false);
  const [rehearsalConfirmed, setRehearsalConfirmed] = useState(false);
  const [rehearsalError, setRehearsalError] = useState<string | null>(null);
  const [retryingRehearsalId, setRetryingRehearsalId] = useState<number | null>(null);
  const [trainingSourceId, setTrainingSourceId] = useState<number | null>(null);
  const [trainingPreview, setTrainingPreview] = useState<TrainingReplayPreview | null>(null);
  const [trainingName, setTrainingName] = useState('');
  const [trainingAssignments, setTrainingAssignments] = useState<Record<number, 'operator' | 'reviewer' | 'workspace_admin'>>({});
  const [loadingTraining, setLoadingTraining] = useState(false);
  const [creatingTraining, setCreatingTraining] = useState(false);
  const [trainingConfirmed, setTrainingConfirmed] = useState(false);
  const [trainingError, setTrainingError] = useState<string | null>(null);
  const trainingPreviewRequestIdRef = useRef(0);
  const [promotionRehearsalId, setPromotionRehearsalId] = useState<number | null>(null);
  const [promotionPreview, setPromotionPreview] = useState<MigrationPromotionPreview | null>(null);
  const [loadingPromotion, setLoadingPromotion] = useState(false);
  const [promotionAction, setPromotionAction] = useState<'backup' | 'apply' | null>(null);
  const [promotionConfirmed, setPromotionConfirmed] = useState(false);
  const [promotionDispositions, setPromotionDispositions] = useState<Record<number, PromotionPaymentDisposition>>({});
  const [promotionError, setPromotionError] = useState<string | null>(null);
  const [promotionNotice, setPromotionNotice] = useState<string | null>(null);
  const promotionPreviewRequestIdRef = useRef(0);
  const productionCompanies = companies.filter(company => !isTestWorkspace(company));
  const testWorkspaces = companies.filter(isTestWorkspace);
  const allPromotionDispositionsSelected = Boolean(promotionPreview?.source_periods.length) &&
    promotionPreview!.source_periods.every(period => Boolean(promotionDispositions[period.id]));
  const groupedCompanies = [
    { label: 'Production clients', companies: productionCompanies },
    { label: 'Test workspaces', companies: testWorkspaces },
  ].filter(group => group.companies.length > 0);
  const orderedCompanies = groupedCompanies.flatMap(group => group.companies);
  const groupStartLabels = new Map(groupedCompanies.map(group => [group.companies[0].id, group.label]));

  const load = useCallback(async (quiet = false) => {
    try {
      if (!quiet) setLoading(true);
      setError(null);
      const data = await companiesApi.list();
      setCompanies(data.companies);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load clients');
    } finally {
      if (!quiet) setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  useEffect(() => {
    if (!companies.some(company => company.migration_rehearsal_status === 'pending')) return;
    const timer = window.setTimeout(() => { void load(true); }, 3000);
    return () => window.clearTimeout(timer);
  }, [companies, load]);

  const refreshPromotionPreview = useCallback(async (rehearsalId: number, quiet = false) => {
    const requestId = ++promotionPreviewRequestIdRef.current;
    if (!quiet) setLoadingPromotion(true);
    setPromotionError(null);
    try {
      const response = await companiesApi.migrationPromotionPreview(rehearsalId);
      if (promotionPreviewRequestIdRef.current === requestId) {
        setPromotionPreview(response.migration_promotion);
        setPromotionDispositions(current => Object.fromEntries(
          response.migration_promotion.source_periods
            .filter(period => current[period.id])
            .map(period => [period.id, current[period.id]]),
        ));
        setPromotionConfirmed(false);
      }
    } catch (err) {
      if (promotionPreviewRequestIdRef.current === requestId) {
        setPromotionError(err instanceof Error ? err.message : 'Could not check the rehearsal promotion');
      }
    } finally {
      if (!quiet && promotionPreviewRequestIdRef.current === requestId) setLoadingPromotion(false);
    }
  }, []);

  useEffect(() => {
    if (!promotionRehearsalId || promotionPreview?.backup?.status !== 'pending') return;
    const timer = window.setTimeout(() => {
      void refreshPromotionPreview(promotionRehearsalId, true);
      void load(true);
    }, 3000);
    return () => window.clearTimeout(timer);
  }, [load, promotionPreview, promotionRehearsalId, refreshPromotionPreview]);

  const handleOpenRehearsal = async (company: CompanyListItem) => {
    setWorkspaceBuilderOpen(false);
    handleCloseTraining();
    handleClosePromotion();
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

  const handleOpenTraining = async (company: CompanyListItem) => {
    setWorkspaceBuilderOpen(false);
    const requestId = ++trainingPreviewRequestIdRef.current;
    handleCloseRehearsal();
    handleClosePromotion();
    setTrainingSourceId(company.id);
    setTrainingPreview(null);
    setTrainingName(`${company.name} Training Replay`);
    setTrainingAssignments({});
    setTrainingConfirmed(false);
    setTrainingError(null);
    setLoadingTraining(true);
    try {
      const response = await companiesApi.trainingReplayPreview(company.id);
      if (trainingPreviewRequestIdRef.current === requestId) setTrainingPreview(response.training_replay);
    } catch (err) {
      if (trainingPreviewRequestIdRef.current === requestId) {
        setTrainingError(err instanceof Error ? err.message : 'Could not prepare the training preview');
      }
    } finally {
      if (trainingPreviewRequestIdRef.current === requestId) setLoadingTraining(false);
    }
  };

  const handleCloseTraining = () => {
    trainingPreviewRequestIdRef.current += 1;
    setTrainingSourceId(null);
    setTrainingPreview(null);
    setTrainingAssignments({});
    setTrainingConfirmed(false);
    setTrainingError(null);
  };

  const handleCreateTraining = async () => {
    if (!trainingSourceId || !trainingPreview?.ready || !trainingConfirmed) return;
    setCreatingTraining(true);
    setTrainingError(null);
    try {
      await companiesApi.createTrainingReplay(trainingSourceId, {
        name: trainingName.trim(),
        acknowledgement: 'CREATE TRAINING REPLAY',
        assignments: Object.entries(trainingAssignments).map(([userId, workspaceAccessLevel]) => ({
          user_id: Number(userId),
          workspace_access_level: workspaceAccessLevel,
        })),
      });
      handleCloseTraining();
      await load();
      await refreshCompanies();
    } catch (err) {
      setTrainingError(err instanceof Error ? err.message : 'Could not create the training replay');
    } finally {
      setCreatingTraining(false);
    }
  };

  const handleOpenPromotion = (company: CompanyListItem) => {
    handleCloseWorkspaceBuilder();
    handleCloseRehearsal();
    handleCloseTraining();
    setPromotionRehearsalId(company.id);
    setPromotionPreview(null);
    setPromotionDispositions({});
    setPromotionConfirmed(false);
    setPromotionError(null);
    setPromotionNotice(null);
    void refreshPromotionPreview(company.id);
  };

  const handleClosePromotion = () => {
    promotionPreviewRequestIdRef.current += 1;
    setPromotionRehearsalId(null);
    setPromotionPreview(null);
    setPromotionDispositions({});
    setPromotionConfirmed(false);
    setPromotionError(null);
    setPromotionAction(null);
  };

  const handleCreatePromotionBackup = async () => {
    if (!promotionRehearsalId || !promotionPreview?.ready_to_back_up || !promotionConfirmed) return;
    setPromotionAction('backup');
    setPromotionError(null);
    try {
      await companiesApi.createMigrationPromotionBackup(promotionRehearsalId, 'CREATE READ-ONLY BACKUP');
      await Promise.all([load(true), refreshCompanies()]);
      await refreshPromotionPreview(promotionRehearsalId, true);
    } catch (err) {
      setPromotionError(err instanceof Error ? err.message : 'Could not create the clean-client backup');
    } finally {
      setPromotionAction(null);
    }
  };

  const handleApplyPromotion = async () => {
    if (!promotionRehearsalId || !promotionPreview?.ready_to_apply || !promotionConfirmed ||
      !promotionPreview.source_periods.every(period => promotionDispositions[period.id])) return;
    setPromotionAction('apply');
    setPromotionError(null);
    try {
      const response = await companiesApi.applyMigrationPromotion(
        promotionRehearsalId,
        'APPLY REHEARSAL TO LIVE CLIENT',
        promotionDispositions,
      );
      const targetName = response.company.name;
      handleClosePromotion();
      setPromotionNotice(`${targetName} now has the verified rehearsal setup and both migrated payrolls.`);
      await Promise.all([load(), refreshCompanies()]);
    } catch (err) {
      setPromotionError(err instanceof Error ? err.message : 'Could not apply the rehearsal to the clean client');
    } finally {
      setPromotionAction(null);
    }
  };

  const handleRetryWorkspace = async (company: CompanyListItem) => {
    setRetryingRehearsalId(company.id);
    setError(null);
    try {
      if (company.test_workspace_purpose === 'training_replay') {
        await companiesApi.retryTrainingReplay(company.id);
      } else {
        await companiesApi.retryMigrationRehearsal(company.id);
      }
      await load();
      await refreshCompanies();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not retry the test workspace copy');
    } finally {
      setRetryingRehearsalId(null);
    }
  };

  const handleOpenReadyRehearsal = (companyId: number) => {
    switchCompany(companyId);
    navigate(`/companies/${companyId}/pay-runs`);
  };

  const handleAddNew = () => {
    setWorkspaceBuilderOpen(false);
    handleCloseRehearsal();
    handleCloseTraining();
    handleClosePromotion();
    setEditingId(null);
    setForm({ ...emptyForm });
    setFormError(null);
    setShowForm(true);
  };

  const handleOpenWorkspaceBuilder = () => {
    setShowForm(false);
    handleCloseRehearsal();
    handleCloseTraining();
    handleClosePromotion();
    setWorkspaceBuilderSourceId(productionCompanies.length === 1 ? productionCompanies[0].id : null);
    setWorkspaceBuilderOpen(true);
  };

  const handleCloseWorkspaceBuilder = () => {
    setWorkspaceBuilderOpen(false);
    setWorkspaceBuilderSourceId(null);
  };

  const workspaceBuilderSource = productionCompanies.find(company => company.id === workspaceBuilderSourceId);

  const handleEdit = async (id: number) => {
    handleCloseWorkspaceBuilder();
    handleCloseRehearsal();
    handleCloseTraining();
    handleClosePromotion();
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
        client_payroll_approval_required: c.client_payroll_approval_required === true,
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

  const openClientIntegrations = (companyId: number) => {
    switchCompany(companyId);
    navigate('/time-tracking-sources');
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
        {promotionNotice && (
          <div role="status" className="flex items-start justify-between gap-4 rounded-xl border border-success-100 bg-success-50 p-4 text-sm text-success-800">
            <div className="flex items-start gap-3"><ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" /><span>{promotionNotice}</span></div>
            <button type="button" onClick={() => setPromotionNotice(null)} aria-label="Dismiss promotion confirmation" className="text-success-700 hover:text-success-800"><X className="h-4 w-4" /></button>
          </div>
        )}

        {/* Primary actions */}
        {canManageClients && !showForm && (
          <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <div className="flex flex-col items-stretch gap-2 sm:items-end">
              <Button variant="outline" onClick={handleOpenWorkspaceBuilder} aria-expanded={workspaceBuilderOpen} disabled={productionCompanies.length === 0}>
                <FlaskConical className="mr-2 h-4 w-4" />
                Create test workspace
              </Button>
              {productionCompanies.length === 0 && <p className="text-xs text-neutral-500">Add a production client before creating a test workspace.</p>}
            </div>
            <Button onClick={handleAddNew}>
              <Plus className="w-4 h-4 mr-2" />
              Add New Client
            </Button>
          </div>
        )}

        {workspaceBuilderOpen && (
          <Card className="overflow-hidden border-primary-200">
            <div className="border-b border-primary-100 bg-primary-50/70 p-4 sm:p-6">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Guided setup</p>
                  <h2 className="mt-2 text-lg font-semibold tracking-tight text-neutral-950">Create a test workspace</h2>
                  <p className="mt-2 max-w-2xl text-sm leading-6 text-neutral-600">Choose the live client first, then choose what the workspace is for. The live client remains unchanged.</p>
                </div>
                <Button variant="ghost" size="sm" onClick={handleCloseWorkspaceBuilder} aria-label="Close test workspace setup">
                  <X className="h-4 w-4" />
                </Button>
              </div>
            </div>
            <div className="grid gap-6 p-4 sm:p-6 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
              <div>
                <div className="flex items-center gap-2">
                  <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary-700 text-xs font-bold text-white">1</span>
                  <label htmlFor="test-workspace-source" className="text-sm font-semibold text-neutral-900">Choose a production client</label>
                </div>
                <Select
                  id="test-workspace-source"
                  className="mt-4"
                  value={workspaceBuilderSourceId ?? ''}
                  onChange={event => setWorkspaceBuilderSourceId(event.target.value ? Number(event.target.value) : null)}
                >
                  <option value="">Select a production client</option>
                  {productionCompanies.map(company => <option key={company.id} value={company.id}>{company.name}</option>)}
                </Select>
                <p className="mt-2 text-xs leading-5 text-neutral-500">Only production clients appear here. Existing test workspaces and backups cannot be copied again.</p>
              </div>
              <div>
                <div className="flex items-center gap-2">
                  <span className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${workspaceBuilderSource ? 'bg-primary-700 text-white' : 'bg-neutral-200 text-neutral-500'}`}>2</span>
                  <p className="text-sm font-semibold text-neutral-900">Choose the goal</p>
                </div>
                <div className="mt-4 grid gap-4 sm:grid-cols-2">
                  <button
                    type="button"
                    disabled={!workspaceBuilderSource}
                    onClick={() => workspaceBuilderSource && void handleOpenTraining(workspaceBuilderSource)}
                    className="group rounded-xl border border-neutral-200 bg-white p-4 text-left transition hover:-translate-y-0.5 hover:border-primary-300 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 disabled:pointer-events-none disabled:opacity-50"
                  >
                    <GraduationCap aria-hidden="true" className="h-5 w-5 text-primary-700" />
                    <span className="mt-4 block font-semibold text-neutral-950">Practice completed payrolls</span>
                    <span className="mt-2 block text-xs font-semibold uppercase tracking-wide text-primary-700">Training replay</span>
                    <span className="mt-2 block text-sm leading-5 text-neutral-600">A trainee safely reproduces the latest two real payrolls and compares results.</span>
                  </button>
                  <button
                    type="button"
                    disabled={!workspaceBuilderSource}
                    onClick={() => workspaceBuilderSource && void handleOpenRehearsal(workspaceBuilderSource)}
                    className="group rounded-xl border border-neutral-200 bg-white p-4 text-left transition hover:-translate-y-0.5 hover:border-warning-300 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 disabled:pointer-events-none disabled:opacity-50"
                  >
                    <FlaskConical aria-hidden="true" className="h-5 w-5 text-warning-700" />
                    <span className="mt-4 block font-semibold text-neutral-950">Rehearse a migration</span>
                    <span className="mt-2 block text-xs font-semibold uppercase tracking-wide text-warning-700">Migration test</span>
                    <span className="mt-2 block text-sm leading-5 text-neutral-600">Review imported employee and payroll data in a protected working copy.</span>
                  </button>
                </div>
              </div>
            </div>
          </Card>
        )}

        {rehearsalSourceId && (
          <Card className="border-amber-200 p-4 sm:p-6">
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
              <p className="mt-6 text-sm text-neutral-500">Checking the source archive…</p>
            ) : rehearsalPreview && (
              <div className="mt-6 space-y-4">
                <div className="grid gap-3 sm:grid-cols-4">
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Employees</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.employees ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Imported pay periods</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.imported_pay_periods ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Imported paychecks</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.imported_paychecks ?? 0}</p></div>
                  <div className="rounded-xl bg-neutral-50 p-3"><p className="text-xs text-neutral-500">Source evidence</p><p className="mt-1 font-semibold">{rehearsalPreview.copy_summary.retained_source_files ?? 0} files · {formatBytes(rehearsalPreview.copy_summary.source_file_bytes)}</p></div>
                </div>

                <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">
                  <p className="font-semibold text-neutral-900">Copy boundaries</p>
                  <ul className="mt-2 list-disc space-y-1 pl-6">{rehearsalPreview.warnings.map(item => <li key={item}>{item}</li>)}</ul>
                </div>

                {rehearsalPreview.blockers.length > 0 && (
                  <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
                    <div className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Not ready to copy</div>
                    <ul className="mt-2 list-disc space-y-1 pl-6">{rehearsalPreview.blockers.map(item => <li key={item}>{item}</li>)}</ul>
                  </div>
                )}

                {rehearsalPreview.ready && (
                  <>
                    <div className="rounded-xl border border-success-100 bg-success-50 p-4 text-sm text-success-800">
                      <div className="flex items-center gap-2 font-semibold"><ShieldCheck className="h-4 w-4" />Built-in safety</div>
                      <p className="mt-1 leading-6">The original remains untouched. Practice runs are always parallel-only and cannot be committed. Check, payment, and official filing actions are blocked.</p>
                    </div>
                    <div className="max-w-xl">
                      <label htmlFor={rehearsalNameId} className="mb-1 block text-sm font-medium text-neutral-700">Rehearsal name</label>
                      <Input id={rehearsalNameId} value={rehearsalName} onChange={event => setRehearsalName(event.target.value)} />
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
            <div className="mt-6 flex justify-end gap-3 border-t border-neutral-200 pt-4">
              <Button variant="outline" onClick={handleCloseRehearsal}>Cancel</Button>
              <Button onClick={handleCreateRehearsal} disabled={!rehearsalPreview?.ready || !rehearsalConfirmed || !rehearsalName.trim() || creatingRehearsal}>
                <FlaskConical className="mr-2 h-4 w-4" />{creatingRehearsal ? 'Creating verified copy…' : 'Create migration test'}
              </Button>
            </div>
          </Card>
        )}

        {trainingSourceId && (
          <Card className="border-primary-200 p-4 sm:p-6">
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-start gap-4">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-100 text-primary-800">
                  <GraduationCap className="h-5 w-5" />
                </div>
                <div>
                  <h3 className="font-semibold text-neutral-950">Create a payroll training replay</h3>
                  <p className="mt-2 max-w-3xl text-sm leading-6 text-neutral-600">
                    Give a staff member two real payroll periods to process safely. Cornerstone copies the setup and earlier year-to-date history, then loads only the inputs from the latest two committed payrolls.
                  </p>
                </div>
              </div>
              <Button variant="ghost" size="sm" onClick={handleCloseTraining} aria-label="Close training replay setup">
                <X className="h-4 w-4" />
              </Button>
            </div>

            {loadingTraining ? (
              <p className="mt-6 text-sm text-neutral-500">Checking the latest payrolls…</p>
            ) : trainingPreview && (
              <div className="mt-6 space-y-4">
                <div className="grid gap-4 sm:grid-cols-3">
                  <div className="rounded-xl bg-neutral-50 p-4"><p className="text-xs text-neutral-500">Employees</p><p className="mt-2 font-semibold">{trainingPreview.copy_summary.active_employees} active · {trainingPreview.copy_summary.employees} total</p></div>
                  <div className="rounded-xl bg-neutral-50 p-4">
                    <p className="flex items-center gap-2 text-xs text-neutral-500">Locked YTD baseline <HelpTip label="locked YTD baseline">Earlier committed payrolls are copied only to preserve accurate year-to-date totals. Trainees can view them but cannot edit them.</HelpTip></p>
                    <p className="mt-2 font-semibold">{trainingPreview.copy_summary.baseline_pay_periods} earlier pay periods</p>
                  </div>
                  <div className="rounded-xl bg-neutral-50 p-4">
                    <p className="flex items-center gap-2 text-xs text-neutral-500">Practice payrolls <HelpTip label="practice payrolls">The latest two committed payrolls are recreated with their original inputs but without their calculated results. The trainee processes them oldest first.</HelpTip></p>
                    <p className="mt-2 font-semibold">{trainingPreview.copy_summary.practice_pay_periods} payroll periods</p>
                  </div>
                </div>

                <div className="rounded-xl border border-neutral-200 p-4">
                  <p className="text-sm font-semibold text-neutral-900">Payrolls the trainee will reproduce</p>
                  <div className="mt-4 grid gap-4 sm:grid-cols-2">
                    {trainingPreview.practice_periods.map((period, index) => (
                      <div key={period.id} className="rounded-lg bg-neutral-50 p-4 text-sm">
                        <p className="font-semibold text-neutral-900">Practice {index + 1}</p>
                        <p className="mt-2 text-neutral-600">{formatShortDate(period.start_date)}–{formatShortDate(period.end_date)}</p>
                        <p className="mt-2 text-xs text-neutral-500">Pay date {formatShortDate(period.pay_date)} · {period.employee_count} employees · <span className="capitalize">{period.status}</span></p>
                      </div>
                    ))}
                  </div>
                </div>

                {trainingPreview.blockers.length > 0 && (
                  <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
                    <div className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Not ready to copy</div>
                    <ul className="mt-2 list-disc space-y-2 pl-6">{trainingPreview.blockers.map(item => <li key={item}>{item}</li>)}</ul>
                  </div>
                )}

                {trainingPreview.ready && (
                  <>
                    <div className="rounded-xl border border-success-100 bg-success-50 p-4 text-sm text-success-800">
                      <div className="flex items-center gap-2 font-semibold"><ShieldCheck className="h-4 w-4" />Safe by design</div>
                      <p className="mt-2 leading-6">The live client remains untouched. Expected results stay in the live benchmark and appear only in comparison after the trainee calculates. Commit, payment, check issuance, filing, reminders, and client communications remain blocked.</p>
                    </div>

                    <div className="max-w-xl">
                      <label htmlFor={trainingNameId} className="mb-2 block text-sm font-medium text-neutral-700">Training workspace name</label>
                      <Input id={trainingNameId} value={trainingName} onChange={event => setTrainingName(event.target.value)} />
                    </div>

                    <div>
                      <p className="text-sm font-semibold text-neutral-900">Who should have access?</p>
                      <p className="mt-2 text-sm text-neutral-600">Admins already have full access. Select the managers and accountants who should train or review.</p>
                      <div className="mt-4"><WorkspaceRoleGuide /></div>
                      <div className="mt-4 divide-y divide-neutral-200 rounded-xl border border-neutral-200">
                        {trainingPreview.assignable_staff.map(staff => {
                          const access = trainingAssignments[staff.id];
                          return (
                            <div key={staff.id} className="flex flex-col gap-4 p-4 sm:flex-row sm:items-center sm:justify-between">
                              <label className="flex cursor-pointer items-start gap-2">
                                <input
                                  type="checkbox"
                                  checked={Boolean(access)}
                                  onChange={event => setTrainingAssignments(current => {
                                    const next = { ...current };
                                    if (event.target.checked) next[staff.id] = 'operator';
                                    else delete next[staff.id];
                                    return next;
                                  })}
                                  className="mt-0.5 h-4 w-4 rounded border-neutral-300"
                                />
                                <span><span className="block text-sm font-medium text-neutral-900">{staff.name}</span><span className="mt-1 block text-xs text-neutral-500">{staff.email} · {staff.role}</span></span>
                              </label>
                              {access && (
                                <Select
                                  aria-label={`Access level for ${staff.name}`}
                                  value={access}
                                  onChange={event => setTrainingAssignments(current => ({ ...current, [staff.id]: event.target.value as 'operator' | 'reviewer' | 'workspace_admin' }))}
                                  className="sm:w-48"
                                >
                                  <option value="operator">Operator — process</option>
                                  <option value="reviewer">Reviewer — review</option>
                                  <option value="workspace_admin">Workspace admin</option>
                                </Select>
                              )}
                            </div>
                          );
                        })}
                      </div>
                    </div>

                    <label className="flex cursor-pointer items-start gap-2 rounded-xl border border-neutral-200 p-4 text-sm text-neutral-700">
                      <input type="checkbox" checked={trainingConfirmed} onChange={event => setTrainingConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 rounded border-neutral-300" />
                      <span>I understand this workspace contains protected payroll and employee data and is limited to the selected payroll staff for 90 days.</span>
                    </label>
                  </>
                )}
              </div>
            )}

            {trainingError && <div className="mt-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{trainingError}</div>}
            <div className="mt-6 flex justify-end gap-4 border-t border-neutral-200 pt-4">
              <Button variant="outline" onClick={handleCloseTraining}>Cancel</Button>
              <Button
                onClick={handleCreateTraining}
                disabled={!trainingPreview?.ready || !trainingConfirmed || !trainingName.trim() || Object.keys(trainingAssignments).length === 0 || creatingTraining}
              >
                <GraduationCap className="mr-2 h-4 w-4" />{creatingTraining ? 'Creating training copy…' : 'Create training replay'}
              </Button>
            </div>
          </Card>
        )}

        {promotionRehearsalId && (
          <Card className="overflow-hidden border-primary-200">
            <div className="border-b border-primary-100 bg-primary-50/70 p-4 sm:p-6">
              <div className="flex items-start justify-between gap-4">
                <div className="flex items-start gap-4">
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-100 text-primary-800">
                    <ShieldCheck className="h-5 w-5" />
                  </div>
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Verified migration handoff</p>
                    <h3 className="mt-1 text-lg font-semibold tracking-tight text-neutral-950">Move rehearsal results to the clean client</h3>
                    <p className="mt-2 max-w-3xl text-sm leading-6 text-neutral-600">
                      Cornerstone verifies the employee match and both payrolls, takes a sealed backup, then applies everything in one transaction. Nothing is sent, printed, filed, or synced externally.
                    </p>
                  </div>
                </div>
                <Button variant="ghost" size="sm" onClick={handleClosePromotion} aria-label="Close migration handoff">
                  <X className="h-4 w-4" />
                </Button>
              </div>
            </div>

            <div className="p-4 sm:p-6">
              {loadingPromotion ? (
                <div role="status" className="flex items-center gap-3 py-8 text-sm text-neutral-600">
                  <RefreshCw className="h-4 w-4 animate-spin" />Verifying the rehearsal, clean client, and backup…
                </div>
              ) : promotionPreview && (
                <div className="space-y-6">
                  <div className="grid gap-3 lg:grid-cols-[1fr_auto_1fr] lg:items-center">
                    <div className="rounded-xl border border-amber-200 bg-amber-50 p-4">
                      <p className="text-xs font-bold uppercase tracking-wide text-amber-800">Rehearsal source</p>
                      <p className="mt-2 font-semibold text-neutral-950">{promotionPreview.rehearsal.name}</p>
                      <p className="mt-1 text-sm text-neutral-600">
                        {promotionPreview.rehearsal.employee_count} employees · {promotionPreview.source_periods.length} reviewed {promotionPreview.source_periods.length === 1 ? 'payroll' : 'payrolls'}
                      </p>
                    </div>
                    <ArrowRight className="mx-auto hidden h-5 w-5 text-neutral-400 lg:block" />
                    <div className="rounded-xl border border-primary-200 bg-primary-50 p-4">
                      <p className="text-xs font-bold uppercase tracking-wide text-primary-800">Clean client destination</p>
                      <p className="mt-2 font-semibold text-neutral-950">{promotionPreview.target_company?.name || 'Missing clean client'}</p>
                      <p className="mt-1 text-sm text-neutral-600">{promotionPreview.target_company?.employee_count ?? 0} employee records</p>
                    </div>
                  </div>

                  <div className="grid gap-3 sm:grid-cols-3">
                    <div className="border-l-2 border-success-500 px-4 py-2"><p className="flex items-center gap-2 text-xs text-neutral-500">Employees matched <HelpTip label="employees matched">Existing clean-client employees that Cornerstone matched to the rehearsal by protected identity fields.</HelpTip></p><p className="mt-1 text-xl font-semibold text-neutral-950">{promotionPreview.employee_mapping.matched}</p></div>
                    <div className="border-l-2 border-primary-500 px-4 py-2"><p className="flex items-center gap-2 text-xs text-neutral-500">New employees to add <HelpTip label="new employees to add">Employees found in the rehearsal but not in the clean client. They will be added during the verified handoff.</HelpTip></p><p className="mt-1 text-xl font-semibold text-neutral-950">{promotionPreview.employee_mapping.new}</p></div>
                    <div className="border-l-2 border-amber-500 px-4 py-2"><p className="flex items-center gap-2 text-xs text-neutral-500">Empty drafts replaced <HelpTip label="empty drafts replaced">Matching clean-client drafts can be replaced only when they contain no payroll results. Drafts with work in them block the handoff.</HelpTip></p><p className="mt-1 text-xl font-semibold text-neutral-950">{promotionPreview.replaceable_drafts.length}</p></div>
                  </div>

                  <div>
                    <p className="text-sm font-semibold text-neutral-900">Choose how each payroll should continue</p>
                    <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-600">
                      Tell Cornerstone whether each rehearsal payroll was already paid elsewhere or still needs to be paid from the clean client.
                    </p>
                    <div className="mt-3 grid gap-3 md:grid-cols-2">
                      {promotionPreview.source_periods.map((period, index) => (
                        <div key={period.id} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                          <div className="flex items-center justify-between gap-3">
                            <p className="text-sm font-semibold text-neutral-900">Payroll {index + 1}</p>
                            <Badge variant="default"><span className="capitalize">{period.status}</span></Badge>
                          </div>
                          <p className="mt-2 text-sm text-neutral-600">{formatShortDate(period.start_date)}–{formatShortDate(period.end_date)}</p>
                          <p className="mt-1 text-xs text-neutral-500">Pay date {formatShortDate(period.pay_date)} · {period.employee_count} employees</p>
                          <div className="mt-3 flex gap-6 border-t border-neutral-200 pt-3 text-sm"><span><span className="text-neutral-500">Gross </span><strong>{formatMoney(period.gross_pay)}</strong></span><span><span className="text-neutral-500">Net </span><strong>{formatMoney(period.net_pay)}</strong></span></div>
                          <fieldset className="mt-4 space-y-2">
                            <legend className="sr-only">Payment status for payroll {index + 1}</legend>
                            <label className={`flex cursor-pointer items-start gap-3 rounded-xl border bg-white p-3 transition ${promotionDispositions[period.id] === 'record_only' ? 'border-primary-400 ring-2 ring-primary-100' : 'border-neutral-200 hover:border-primary-200'}`}>
                              <input
                                type="radio"
                                name={`promotion-disposition-${period.id}`}
                                value="record_only"
                                checked={promotionDispositions[period.id] === 'record_only'}
                                onChange={() => {
                                  setPromotionDispositions(current => ({ ...current, [period.id]: 'record_only' }));
                                  setPromotionConfirmed(false);
                                }}
                                className="mt-1 h-4 w-4 border-neutral-300 text-primary-700"
                              />
                              <span>
                                <span className="block text-sm font-semibold text-neutral-900">Already paid elsewhere — record only</span>
                                <span className="mt-1 block text-xs leading-5 text-neutral-600">Save it as a locked historical payroll and rebuild YTD totals. No checks or payment actions will be created.</span>
                              </span>
                            </label>
                            <label className={`flex cursor-pointer items-start gap-3 rounded-xl border bg-white p-3 transition ${promotionDispositions[period.id] === 'process_in_cornerstone' ? 'border-primary-400 ring-2 ring-primary-100' : 'border-neutral-200 hover:border-primary-200'}`}>
                              <input
                                type="radio"
                                name={`promotion-disposition-${period.id}`}
                                value="process_in_cornerstone"
                                checked={promotionDispositions[period.id] === 'process_in_cornerstone'}
                                onChange={() => {
                                  setPromotionDispositions(current => ({ ...current, [period.id]: 'process_in_cornerstone' }));
                                  setPromotionConfirmed(false);
                                }}
                                className="mt-1 h-4 w-4 border-neutral-300 text-primary-700"
                              />
                              <span>
                                <span className="block text-sm font-semibold text-neutral-900">Unpaid — process in Cornerstone</span>
                                <span className="mt-1 block text-xs leading-5 text-neutral-600">Bring it in as calculated. Review, approve, and commit it normally before assigning and printing checks.</span>
                              </span>
                            </label>
                          </fieldset>
                        </div>
                      ))}
                    </div>
                    {promotionPreview.ready_to_apply && !allPromotionDispositionsSelected && (
                      <p role="alert" className="mt-3 flex items-center gap-2 text-sm font-medium text-amber-800">
                        <AlertTriangle className="h-4 w-4 shrink-0" />Choose a payment status for every payroll before applying the rehearsal.
                      </p>
                    )}
                  </div>

                  <div className="grid gap-4 lg:grid-cols-2">
                    <div className={`rounded-xl border p-4 ${promotionPreview.backup?.status === 'ready' && promotionPreview.backup.current ? 'border-success-100 bg-success-50' : 'border-neutral-200 bg-neutral-50'}`}>
                      <div className="flex items-start gap-3">
                        <div className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-sm font-bold ${promotionPreview.backup?.status === 'ready' && promotionPreview.backup.current ? 'bg-success-600 text-white' : 'bg-neutral-200 text-neutral-700'}`}>1</div>
                        <div>
                          <p className="flex items-center gap-2 font-semibold text-neutral-950">Seal a clean-client backup <HelpTip label="current backup">A backup is current only while the clean client remains unchanged after the backup was created. Any later change requires a fresh backup.</HelpTip></p>
                          {promotionPreview.backup ? (
                            <p className="mt-1 text-sm leading-6 text-neutral-600">
                              {promotionPreview.backup.status === 'pending'
                                ? 'The backup is being copied and verified now. This page will refresh automatically.'
                                : promotionPreview.backup.status === 'failed'
                                  ? 'The last backup did not finish. Create a replacement before applying.'
                                  : promotionPreview.backup.current
                                    ? `${promotionPreview.backup.name} is verified and read only.`
                                    : 'The clean client changed after this backup. Create a fresh replacement.'}
                            </p>
                          ) : <p className="mt-1 text-sm leading-6 text-neutral-600">Required before the clean client can change. The backup keeps its current setup, archive, and empty draft.</p>}
                        </div>
                      </div>
                    </div>
                    <div className={`rounded-xl border p-4 ${promotionPreview.ready_to_apply ? 'border-primary-200 bg-primary-50' : 'border-neutral-200 bg-neutral-50'}`}>
                      <div className="flex items-start gap-3">
                        <div className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-sm font-bold ${promotionPreview.ready_to_apply ? 'bg-primary-700 text-white' : 'bg-neutral-200 text-neutral-700'}`}>2</div>
                        <div>
                          <p className="font-semibold text-neutral-950">Apply setup and both payrolls</p>
                          <p className="mt-1 text-sm leading-6 text-neutral-600">Replaces only the verified setup and matching empty draft. Paid payrolls become locked records; unpaid payrolls return to the normal review-and-payment workflow. The rehearsal is then sealed.</p>
                        </div>
                      </div>
                    </div>
                  </div>

                  {promotionPreview.blockers.length > 0 && !promotionPreview.ready_to_back_up && (
                    <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
                      <div className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />Action required</div>
                      <ul className="mt-2 list-disc space-y-1 pl-6">{promotionPreview.blockers.map(item => <li key={item}>{item}</li>)}</ul>
                    </div>
                  )}

                  {(promotionPreview.ready_to_back_up || (promotionPreview.ready_to_apply && allPromotionDispositionsSelected)) && (
                    <label className="flex cursor-pointer items-start gap-3 rounded-xl border border-neutral-300 p-4 text-sm text-neutral-700">
                      <input type="checkbox" checked={promotionConfirmed} onChange={event => setPromotionConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 rounded border-neutral-300" />
                      <span>{promotionPreview.ready_to_apply
                        ? `I reviewed the employee match, both payroll totals, and the verified backup. Apply this rehearsal to ${promotionPreview.target_company?.name}.`
                        : `Create a sealed, read-only backup of ${promotionPreview.target_company?.name} before any migration data is applied.`}</span>
                    </label>
                  )}
                </div>
              )}

              {promotionError && <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{promotionError}</div>}
              <div className="mt-6 flex flex-col-reverse gap-3 border-t border-neutral-200 pt-4 sm:flex-row sm:justify-between">
                <Button variant="outline" onClick={handleClosePromotion}>Cancel</Button>
                <div className="flex flex-col gap-3 sm:flex-row">
                  <Button variant="outline" onClick={() => void refreshPromotionPreview(promotionRehearsalId)} disabled={loadingPromotion || Boolean(promotionAction)}>
                    <RefreshCw className={`mr-2 h-4 w-4 ${loadingPromotion ? 'animate-spin' : ''}`} />Refresh verification
                  </Button>
                  {promotionPreview?.ready_to_back_up && (
                    <Button onClick={handleCreatePromotionBackup} disabled={!promotionConfirmed || Boolean(promotionAction)}>
                      <ShieldCheck className="mr-2 h-4 w-4" />{promotionAction === 'backup' ? 'Creating backup…' : promotionPreview.backup ? 'Replace backup' : 'Create read-only backup'}
                    </Button>
                  )}
                  {promotionPreview?.ready_to_apply && (
                    <Button onClick={handleApplyPromotion} disabled={!promotionConfirmed || !allPromotionDispositionsSelected || Boolean(promotionAction)}>
                      <ArrowRight className="mr-2 h-4 w-4" />{promotionAction === 'apply' ? 'Applying verified migration…' : 'Apply to clean client'}
                    </Button>
                  )}
                </div>
              </div>
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
                    description="Adds a compact payroll register as the first worksheet while preserving the detailed payroll sheets. Leave this off for clients that require a different register format."
                    onToggle={() => updateField('simple_payroll_register_enabled', form.simple_payroll_register_enabled !== true)}
                  />

                  <SettingToggle
                    checked={form.historical_payroll_enabled === true}
                    label="Historical payroll workspace"
                    description="Opens the protected QuickBooks migration workspace for this client. Keep this off until the source bundle is ready for review."
                    onToggle={() => updateField('historical_payroll_enabled', form.historical_payroll_enabled !== true)}
                  />

                  <SettingToggle
                    checked={form.client_payroll_approval_required === true}
                    label="Require client approval before payroll approval"
                    description="Shares each calculated revision in the client portal. Cornerstone cannot approve or commit the run until an assigned client user approves that exact revision, either in the portal or through a retained email attestation."
                    onToggle={() => updateField('client_payroll_approval_required', form.client_payroll_approval_required !== true)}
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

        {canManageClients && <TestWorkspaceGuide />}

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
              ) : orderedCompanies.map((c) => (
                <Fragment key={c.id}>
                  {groupStartLabels.has(c.id) && (
                    <h2 className="px-1 pt-2 text-[11px] font-bold uppercase tracking-[0.14em] text-neutral-500">
                      {groupStartLabels.get(c.id)}
                    </h2>
                  )}
                  <MobileRecordCard>
                  <div className="flex items-start gap-3">
                    <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
                      <Building2 className="h-5 w-5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-semibold text-neutral-950">{c.name}</p>
                          {isTestWorkspace(c) && (
                            <p className="mt-0.5 text-xs font-semibold text-amber-700">{testWorkspaceLabel(c)} · {c.migration_rehearsal_status}</p>
                          )}
                        </div>
                        <Badge variant={c.migration_rehearsal_status === 'pending' ? 'info' : c.migration_rehearsal_status === 'failed' ? 'danger' : c.active !== false ? 'success' : 'default'}>
                          {c.migration_rehearsal_status === 'pending'
                            ? 'Preparing'
                            : c.migration_rehearsal_status === 'failed'
                              ? 'Needs attention'
                              : isReadOnlyWorkspace(c)
                                ? 'Read only'
                                : isTestWorkspace(c)
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
                          {isTestWorkspace(c) && c.migration_rehearsal_status === 'ready' && (
                            <Button size="sm" onClick={() => handleOpenReadyRehearsal(c.id)}>
                              {testWorkspaceOpenLabel(c)} <ArrowRight className="ml-1 h-4 w-4" />
                            </Button>
                          )}
                          {canManageClients && c.test_workspace_purpose === 'migration_rehearsal' && !c.test_workspace_sealed_at && c.migration_rehearsal_status === 'ready' && c.test_workspace_manifest?.promotion_status !== 'completed' && (
                            <Button size="sm" variant="outline" onClick={() => handleOpenPromotion(c)}>
                              <ShieldCheck className="mr-1 h-4 w-4" />Promote rehearsal
                            </Button>
                          )}
                          {!isReadOnlyWorkspace(c) && (
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={() => handleEdit(c.id)}
                              disabled={loadingEditId === c.id || c.migration_rehearsal_status === 'pending'}
                            >
                              <Pencil className="mr-1 h-4 w-4" />
                              {loadingEditId === c.id ? 'Loading...' : 'Edit'}
                            </Button>
                          )}
                          {canManageClients && !isTestWorkspace(c) && (
                            <Button size="sm" variant="outline" onClick={() => openClientIntegrations(c.id)} aria-label={`Time tracking settings for ${c.name}`}>
                              Time tracking
                            </Button>
                          )}
                          {canManageClients && c.migration_rehearsal_status === 'failed' && (
                            <Button size="sm" variant="outline" onClick={() => handleRetryWorkspace(c)} disabled={retryingRehearsalId === c.id}>
                              {retryingRehearsalId === c.id ? 'Retrying…' : 'Retry copy'}
                            </Button>
                          )}
                        </MobileCardActions>
                      )}
                    </div>
                  </div>
                  </MobileRecordCard>
                </Fragment>
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
                  orderedCompanies.map((c) => (
                    <Fragment key={c.id}>
                    {groupStartLabels.has(c.id) && (
                      <TableRow className="bg-neutral-50/80 hover:bg-neutral-50/80">
                        <TableCell colSpan={canEditAssignedClients ? 6 : 5} className="py-2 text-[11px] font-bold uppercase tracking-[0.14em] text-neutral-500">
                          {groupStartLabels.get(c.id)}
                        </TableCell>
                      </TableRow>
                    )}
                    <TableRow>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          {isTestWorkspace(c) ? <FlaskConical className="h-4 w-4 text-amber-700" /> : <Building2 className="w-4 h-4 text-gray-400" />}
                          <div>
                            <span className="font-medium text-gray-900">{c.name}</span>
                            {isTestWorkspace(c) && (
                              <p className="text-xs font-medium text-amber-700">{testWorkspaceLabel(c)} · source: {c.migration_source_company_name || 'linked client'}</p>
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
                          <Badge variant="success">{isReadOnlyWorkspace(c) ? 'Read only' : isTestWorkspace(c) ? 'Ready to test' : 'Active'}</Badge>
                        ) : (
                          <Badge variant="default">Inactive</Badge>
                        )}
                      </TableCell>
                      {canEditAssignedClients && (
                        <TableCell className="text-right">
                          <div className="flex justify-end gap-2">
                            {isTestWorkspace(c) && c.migration_rehearsal_status === 'ready' && (
                              <Button size="sm" onClick={() => handleOpenReadyRehearsal(c.id)} className="text-xs">
                                {testWorkspaceOpenLabel(c)} <ArrowRight className="ml-1 h-3.5 w-3.5" />
                              </Button>
                            )}
                            {canManageClients && c.test_workspace_purpose === 'migration_rehearsal' && !c.test_workspace_sealed_at && c.migration_rehearsal_status === 'ready' && c.test_workspace_manifest?.promotion_status !== 'completed' && (
                              <Button size="sm" variant="outline" onClick={() => handleOpenPromotion(c)} className="text-xs">
                                <ShieldCheck className="mr-1 h-3.5 w-3.5" />Promote rehearsal
                              </Button>
                            )}
                            {canManageClients && c.migration_rehearsal_status === 'failed' && (
                              <Button size="sm" variant="outline" onClick={() => handleRetryWorkspace(c)} disabled={retryingRehearsalId === c.id} className="text-xs">
                                {retryingRehearsalId === c.id ? 'Retrying…' : 'Retry copy'}
                              </Button>
                            )}
                            {!isReadOnlyWorkspace(c) && (
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
                            )}
                            {canManageClients && !isTestWorkspace(c) && (
                              <Button size="sm" variant="outline" className="text-xs" onClick={() => openClientIntegrations(c.id)} aria-label={`Time tracking settings for ${c.name}`}>
                                Time tracking
                              </Button>
                            )}
                          </div>
                        </TableCell>
                      )}
                    </TableRow>
                    </Fragment>
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
