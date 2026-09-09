import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { Link, useParams } from 'react-router';
import {
  AlertTriangle,
  ArrowRight,
  Building2,
  CheckCircle2,
  CircleDashed,
  LockKeyhole,
  Route,
  ShieldCheck,
} from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { useCompany } from '@/contexts/CompanyContext';
import { employeesPath } from '@/lib/routes';
import { formatDate, formatGuamDateTime } from '@/lib/utils';
import { payrollGoLiveApi, type PayrollGoLivePayload, type PayrollGoLiveReview } from '@/services/api';

type SourceTotals = {
  employee_count: string;
  gross_pay: string;
  net_pay: string;
  taxes: string;
  deductions: string;
};

const emptySourceTotals: SourceTotals = {
  employee_count: '', gross_pay: '', net_pay: '', taxes: '', deductions: '',
};

const money = (value: string | number | undefined): string => {
  const parsed = Number(value || 0);
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(parsed);
};

const readinessLabels: Record<string, string> = {
  historical_import_locked: 'Historical import locked',
  historical_ytd_active: 'Historical YTD active',
  company_setup_reviewed: 'Company setup reviewed',
  company_setup_gaps: 'Required company fields missing',
  employees_needing_review: 'Employee setup items open',
  employees_missing_w4: 'Employees missing W-4',
  loan_setup_gaps: 'Loan balance gaps',
  pay_schedule_confirmed: 'Pay schedule confirmed',
  workweek_confirmed: 'Workweek confirmed',
  consecutive_parallel_passes: 'Consecutive parallel passes',
  attestations_complete: 'Attestations complete',
  technical_signoff: 'Technical signoff',
  operations_signoff: 'Operations signoff',
};

function readinessPassed(key: string, value: boolean | number): boolean {
  if (key === 'employees_needing_review' || key === 'employees_missing_w4' || key === 'loan_setup_gaps' || key === 'company_setup_gaps') return value === 0;
  if (key === 'consecutive_parallel_passes') return Number(value) >= 2;
  return value === true;
}

export function PayrollGoLive(): ReactElement {
  const { companyId: companyIdParam } = useParams<{ companyId: string }>();
  const companyId = Number(companyIdParam);
  const { activeCompany, activeCompanyId } = useCompany();
  const [payload, setPayload] = useState<PayrollGoLivePayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [sourceCompanyId, setSourceCompanyId] = useState('');
  const [batchId, setBatchId] = useState('');
  const [effectiveOn, setEffectiveOn] = useState('');
  const [applyAcknowledgement, setApplyAcknowledgement] = useState('');
  const [payPeriodId, setPayPeriodId] = useState('');
  const [sourceTotals, setSourceTotals] = useState<SourceTotals>(emptySourceTotals);
  const [parallelNotes, setParallelNotes] = useState('');
  const [attestations, setAttestations] = useState<Record<string, boolean>>({});
  const [reviewNotes, setReviewNotes] = useState('');
  const [technicalAcknowledgement, setTechnicalAcknowledgement] = useState('');
  const [operationsAcknowledgement, setOperationsAcknowledgement] = useState('');
  const [companySetupNotes, setCompanySetupNotes] = useState('');
  const [companySetupAcknowledgement, setCompanySetupAcknowledgement] = useState('');
  const companySetupNotesDirtyRef = useRef(false);
  const hydratedReviewIdRef = useRef<number | null>(null);

  const load = useCallback(async (): Promise<void> => {
    if (!Number.isInteger(companyId) || companyId <= 0 || activeCompanyId !== companyId) return;
    try {
      setLoading(true);
      setError(null);
      const next = await payrollGoLiveApi.show(companyId);
      setPayload(next);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not load go-live readiness.');
    } finally {
      setLoading(false);
    }
  }, [activeCompanyId, companyId]);

  useEffect(() => { void load(); }, [load]);

  const loadedReview = payload?.data;
  useEffect(() => {
    const review = loadedReview;
    if (!review) return;
    const reviewChanged = hydratedReviewIdRef.current !== review.id;
    setSourceCompanyId(String(review.source_company.id));
    setBatchId(String(review.historical_import_batch_id));
    setEffectiveOn(review.effective_on);
    setAttestations(review.attestations || {});
    setReviewNotes(review.review_notes || '');
    if (reviewChanged || !companySetupNotesDirtyRef.current) {
      setCompanySetupNotes(review.company_setup.review_notes || '');
      companySetupNotesDirtyRef.current = false;
    }
    hydratedReviewIdRef.current = review.id;
  }, [loadedReview]);

  const updateCompanySetupNotes = (value: string): void => {
    companySetupNotesDirtyRef.current = true;
    setCompanySetupNotes(value);
  };

  const selectedPeriod = useMemo(
    () => payload?.eligible_pay_periods.find((period) => period.id === Number(payPeriodId)),
    [payPeriodId, payload?.eligible_pay_periods],
  );

  const runAction = async (
    name: string,
    action: () => Promise<PayrollGoLivePayload>,
    success: string,
    onSuccess?: () => void,
  ): Promise<void> => {
    try {
      setBusy(name);
      setError(null);
      setNotice(null);
      const next = await action();
      onSuccess?.();
      setPayload(next);
      setNotice(success);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The action could not be completed.');
    } finally {
      setBusy(null);
    }
  };

  const previewSetup = (event: FormEvent): void => {
    event.preventDefault();
    void runAction('preview', () => payrollGoLiveApi.preview({
      source_company_id: Number(sourceCompanyId),
      historical_import_batch_id: Number(batchId),
      effective_on: effectiveOn,
    }, companyId), 'Setup preview rebuilt from the current source data.');
  };

  const recordParallel = (event: FormEvent): void => {
    event.preventDefault();
    void runAction('parallel', () => payrollGoLiveApi.recordParallel({
      pay_period_id: Number(payPeriodId), source_totals: sourceTotals, notes: parallelNotes,
    }, companyId), 'Parallel comparison saved. This pay run can no longer be committed.');
  };

  if (loading || activeCompanyId !== companyId) {
    return <div className="flex min-h-[24rem] items-center justify-center text-sm font-medium text-neutral-500">Loading payroll go-live workspace…</div>;
  }

  if (!payload) {
    return <div className="rounded-2xl border border-danger-200 bg-danger-50 p-6 text-danger-800" role="alert"><p className="font-semibold">Go-live workspace unavailable</p><p className="mt-2 text-sm">{error}</p><Button className="mt-4" variant="outline" onClick={() => void load()}>Try again</Button></div>;
  }

  const review = payload.data;
  const sealed = review?.status === 'approved';

  return (
    <div className="space-y-6 pb-12">
      <header className="overflow-hidden rounded-[1.75rem] border border-slate-800 bg-slate-950 px-6 py-7 text-white shadow-xl shadow-slate-950/10 sm:px-8">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <div className="max-w-3xl">
            <div className="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.18em] text-sky-300"><Route className="h-4 w-4" /> Controlled payroll launch</div>
            <h1 className="mt-3 font-display text-3xl font-bold tracking-tight sm:text-4xl">Payroll go-live</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-slate-300">Copy reviewed live setup into {activeCompany?.name || 'the successor client'}, prove two parallel payrolls against QuickBooks, and preserve an attributed approval record.</p>
          </div>
          <Badge className="w-fit border border-white/15 bg-white/10 px-3 py-1.5 text-white">
            {review ? review.status.replace('_', ' ') : 'Not started'}
          </Badge>
        </div>
      </header>

      <div className="grid gap-3 lg:grid-cols-3">
        <Guardrail icon={<LockKeyhole className="h-5 w-5" />} title="Paid history stays locked" text="Imported payroll amounts, checks, YTD rows, and audit history are never copied or edited here." />
        <Guardrail icon={<CircleDashed className="h-5 w-5" />} title="Parallel means unpaid" text="A comparison run can be calculated and approved, but Cornerstone blocks it from being committed." />
        <Guardrail icon={<ShieldCheck className="h-5 w-5" />} title="Two people approve" text="Technical and payroll-operations signoffs must come from different authorized people." />
      </div>

      {(error || notice) && <div className={`rounded-2xl border px-5 py-4 text-sm ${error ? 'border-danger-200 bg-danger-50 text-danger-800' : 'border-success-200 bg-success-50 text-success-700'}`} role={error ? 'alert' : 'status'}>{error || notice}</div>}

      <Card>
        <CardHeader><div className="flex flex-wrap items-start justify-between gap-4"><div><CardTitle>1. Transfer reviewed setup</CardTitle><CardDescription className="mt-1">Match predecessor employees to the successor roster, preview every count, then copy only live configuration.</CardDescription></div>{review?.setup_applied_at && <Badge variant="success">Applied {formatDate(review.setup_applied_at)}</Badge>}</div></CardHeader>
        <CardContent className="space-y-5">
          <form className="grid gap-4 md:grid-cols-3" onSubmit={previewSetup}>
            <FieldSelect label="Predecessor client" value={sourceCompanyId} onChange={setSourceCompanyId} disabled={!payload.permissions.can_preview_setup || sealed || Boolean(review?.setup_applied_at)} required>
              <option value="">Select a client</option>{payload.source_companies.map((company) => <option key={company.id} value={company.id}>{company.name} · {company.employee_count} employees</option>)}
            </FieldSelect>
            <FieldSelect label="Verified QuickBooks import" value={batchId} onChange={setBatchId} disabled={!payload.permissions.can_preview_setup || sealed || Boolean(review?.setup_applied_at)} required>
              <option value="">Select an import</option>{payload.historical_imports.map((batch) => <option key={batch.id} value={batch.id}>{batch.source_label} · {batch.status}</option>)}
            </FieldSelect>
            <Input label="Live setup effective date" type="date" value={effectiveOn} onChange={(event) => setEffectiveOn(event.target.value)} disabled={!payload.permissions.can_preview_setup || sealed || Boolean(review?.setup_applied_at)} required />
            <div className="md:col-span-3"><Button type="submit" variant="outline" disabled={!payload.permissions.can_preview_setup || sealed || Boolean(review?.setup_applied_at) || busy !== null}>{busy === 'preview' ? 'Building preview…' : review ? 'Rebuild preview' : 'Build transfer preview'}</Button></div>
          </form>

          {review && <>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              {Object.entries(review.setup_summary).map(([key, value]) => <Metric key={key} label={key.replaceAll('_', ' ')} value={String(value)} />)}
            </div>
            {review.errors.length > 0 && <MessageList tone="danger" title="Resolve before applying" messages={review.errors} />}
            {review.warnings.length > 0 && <MessageList tone="warning" title="Boundaries to verify" messages={review.warnings} />}
            {!review.setup_applied_at && review.errors.length === 0 && payload.permissions.can_apply_setup && <div className="rounded-2xl border border-primary-200 bg-primary-50 p-5"><p className="font-semibold text-primary-950">Apply the reviewed configuration</p><p className="mt-1 text-sm leading-6 text-primary-800">This copies employee profiles, W-4 elections, rates, departments, recurring definitions, schedule, workweek, and check settings. It does not move the EIN or loan balances.</p><Input className="mt-4 max-w-xl" label={`Type ${payload.acknowledgements.apply_setup}`} value={applyAcknowledgement} onChange={(event) => setApplyAcknowledgement(event.target.value)} /><Button className="mt-4" disabled={applyAcknowledgement !== payload.acknowledgements.apply_setup || busy !== null} onClick={() => void runAction('apply', () => payrollGoLiveApi.apply(applyAcknowledgement, companyId), 'Reviewed setup copied to the successor client.')}>{busy === 'apply' ? 'Applying…' : 'Apply reviewed setup'}</Button></div>}
          </>}
        </CardContent>
      </Card>

      {review && <>
        <Card>
          <CardHeader><CardTitle>2. Resolve readiness checks</CardTitle><CardDescription className="mt-1">Cornerstone staff can open and correct employee setup, W-4 history, loan ledgers, pay schedules, and reports. Imported paid payroll remains read-only.</CardDescription></CardHeader>
          <CardContent className="space-y-5">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{Object.entries(review.readiness).map(([key, value]) => <ReadinessFact key={key} label={readinessLabels[key] || key.replaceAll('_', ' ')} value={value} passed={readinessPassed(key, value)} />)}</div>
            {review.setup_applied_at && <CompanySetupReviewPanel
              review={review.company_setup}
              notes={companySetupNotes}
              acknowledgement={companySetupAcknowledgement}
              onNotesChange={updateCompanySetupNotes}
              onAcknowledgementChange={setCompanySetupAcknowledgement}
              canReview={payload.permissions.can_review_company_setup && !sealed}
              busy={busy === 'company-setup'}
              onConfirm={() => void runAction(
                'company-setup',
                () => payrollGoLiveApi.reviewCompanySetup({ acknowledgement: companySetupAcknowledgement, notes: companySetupNotes }, companyId),
                'Company setup review recorded.',
                () => { companySetupNotesDirtyRef.current = false; },
              )}
            />}
            <div className="flex flex-wrap gap-2">
              <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to={`${employeesPath(companyId)}?configuration_review_status=needs_review`}>Review imported employee setup <ArrowRight className="h-4 w-4" /></Link>
              <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to="/employee-loans">Review loan ledgers <ArrowRight className="h-4 w-4" /></Link>
              <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to="/pay-schedule-settings">Review pay schedule <ArrowRight className="h-4 w-4" /></Link>
              <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to="/reports">Reconcile annual totals <ArrowRight className="h-4 w-4" /></Link>
            </div>
            {review.blockers.length > 0 && <MessageList tone="neutral" title="Still required" messages={review.blockers} />}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>3. Prove parallel payrolls</CardTitle><CardDescription className="mt-1">Enter final QuickBooks totals and compare them with the stored Cornerstone calculation. Saving permanently labels the selected run as non-committable.</CardDescription></CardHeader>
          <CardContent className="space-y-6">
            <form className="space-y-4" onSubmit={recordParallel}>
              <FieldSelect label="Cornerstone comparison pay run" value={payPeriodId} onChange={setPayPeriodId} disabled={!payload.permissions.can_record_parallel || sealed} required>
                <option value="">Select a calculated or approved run</option>{payload.eligible_pay_periods.map((period) => <option key={period.id} value={period.id}>{formatDate(period.start_date)}–{formatDate(period.end_date)} · pay {formatDate(period.pay_date)}{period.parallel_run ? ' · already recorded' : ''}</option>)}
              </FieldSelect>
              {selectedPeriod && <div className="grid gap-3 sm:grid-cols-3"><Metric label="Cornerstone employees" value={String(selectedPeriod.employee_count)} /><Metric label="Cornerstone gross" value={money(selectedPeriod.gross_pay)} /><Metric label="Cornerstone net" value={money(selectedPeriod.net_pay)} /></div>}
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
                {([['employee_count', 'QuickBooks employees'], ['gross_pay', 'QuickBooks gross'], ['net_pay', 'QuickBooks net'], ['taxes', 'QuickBooks taxes'], ['deductions', 'QuickBooks non-tax deductions']] as const).map(([key, label]) => <Input key={key} label={label} type="number" min="0" step={key === 'employee_count' ? '1' : '0.01'} value={sourceTotals[key]} onChange={(event) => setSourceTotals((current) => ({ ...current, [key]: event.target.value }))} disabled={sealed} required />)}
              </div>
              <FieldTextarea label="Comparison evidence and exceptions" value={parallelNotes} onChange={setParallelNotes} disabled={sealed} required />
              <Button type="submit" disabled={sealed || !payload.permissions.can_record_parallel || busy !== null}>{busy === 'parallel' ? 'Comparing…' : 'Save parallel comparison'}</Button>
            </form>

            <div className="space-y-3"><h3 className="font-semibold text-neutral-950">Recorded comparisons</h3>{review.parallel_runs.length === 0 ? <p className="rounded-2xl border border-dashed border-neutral-300 px-5 py-8 text-center text-sm text-neutral-500">No parallel comparisons recorded yet.</p> : review.parallel_runs.map((run) => <div key={run.id} className="rounded-2xl border border-neutral-200 p-4"><div className="flex flex-wrap items-center justify-between gap-3"><div><p className="font-semibold text-neutral-950">Pay date {formatDate(run.pay_date)}</p><p className="mt-1 text-xs text-neutral-500">Recorded {formatGuamDateTime(run.recorded_at)}{run.recorded_by_name ? ` by ${run.recorded_by_name}` : ''}</p></div><Badge variant={run.result === 'pass' ? 'success' : 'danger'}>{run.result === 'pass' ? 'Reconciled' : 'Needs review'}</Badge></div><div className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-5"><Comparison label="Employees" source={run.source_employee_count} target={run.cornerstone_employee_count} /><Comparison label="Gross" source={money(run.source_gross_pay)} target={money(run.cornerstone_gross_pay)} /><Comparison label="Net" source={money(run.source_net_pay)} target={money(run.cornerstone_net_pay)} /><Comparison label="Taxes" source={money(run.source_taxes)} target={money(run.cornerstone_taxes)} /><Comparison label="Deductions" source={money(run.source_deductions)} target={money(run.cornerstone_deductions)} /></div><p className="mt-4 text-sm leading-6 text-neutral-600">{run.notes}</p></div>)}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>4. Approve launch</CardTitle><CardDescription className="mt-1">Complete the operational record, then collect separate technical and operations signoffs. Approval seals this evidence.</CardDescription></CardHeader>
          <CardContent className="space-y-6">
            <div className="space-y-3">{Object.entries(review.attestation_labels).map(([key, label]) => <label key={key} className="flex cursor-pointer items-start gap-3 rounded-xl border border-neutral-200 p-4 hover:border-primary-300"><input className="mt-1 h-4 w-4 accent-primary-700" type="checkbox" checked={Boolean(attestations[key])} onChange={(event) => setAttestations((current) => ({ ...current, [key]: event.target.checked }))} disabled={sealed} /><span className="text-sm leading-6 text-neutral-700">{label}</span></label>)}</div>
            <FieldTextarea label="Final review notes" value={reviewNotes} onChange={setReviewNotes} disabled={sealed} helperText="Document exceptions, owners, QuickBooks fallback access, and the planned first live pay date." />
            {!sealed && <Button variant="outline" disabled={busy !== null} onClick={() => void runAction('review', () => payrollGoLiveApi.updateReview({ attestations, review_notes: reviewNotes }, companyId), 'Operational checklist saved. Any earlier signoff was cleared because the evidence changed.')}>{busy === 'review' ? 'Saving…' : 'Save readiness record'}</Button>}

            <div className="grid gap-4 lg:grid-cols-2">
              <Signoff title="Technical signoff" signedAt={review.technical_signed_at} signedBy={review.technical_signed_by_name} acknowledgement={payload.acknowledgements.technical} value={technicalAcknowledgement} onChange={setTechnicalAcknowledgement} canSign={payload.permissions.can_sign_technical && !sealed} busy={busy === 'technical'} onSign={() => void runAction('technical', () => payrollGoLiveApi.signTechnical(technicalAcknowledgement, companyId), 'Technical signoff recorded.')} />
              <Signoff title="Payroll operations signoff" signedAt={review.operations_signed_at} signedBy={review.operations_signed_by_name} acknowledgement={payload.acknowledgements.operations} value={operationsAcknowledgement} onChange={setOperationsAcknowledgement} canSign={payload.permissions.can_sign_operations && !sealed} busy={busy === 'operations'} onSign={() => void runAction('operations', () => payrollGoLiveApi.signOperations(operationsAcknowledgement, companyId), 'Operations signoff recorded.')} />
            </div>
          </CardContent>
        </Card>
      </>}
    </div>
  );
}

function CompanySetupReviewPanel({
  review,
  notes,
  acknowledgement,
  onNotesChange,
  onAcknowledgementChange,
  canReview,
  busy,
  onConfirm,
}: {
  review: PayrollGoLiveReview['company_setup'];
  notes: string;
  acknowledgement: string;
  onNotesChange: (value: string) => void;
  onAcknowledgementChange: (value: string) => void;
  canReview: boolean;
  busy: boolean;
  onConfirm: () => void;
}): ReactElement {
  const label = review.current
    ? 'Reviewed'
    : review.status === 'stale'
      ? 'Review changed values'
      : review.status === 'missing_required'
        ? 'Missing required fields'
        : 'Needs review';
  const variant = review.current ? 'success' : review.status === 'missing_required' ? 'danger' : 'warning';

  return (
    <div className="rounded-2xl border border-neutral-200 bg-neutral-50/70 p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="max-w-2xl">
          <p className="flex items-center gap-2 font-semibold text-neutral-950"><Building2 className="h-4 w-4 text-primary-700" />Company setup review</p>
          <p className="mt-2 text-sm leading-6 text-neutral-600">Confirm the successor client—not the predecessor—before live payroll. The EIN is intentionally never copied, so Cornerstone must enter and verify it here.</p>
        </div>
        <Badge variant={variant}>{label}</Badge>
      </div>
      <div className="mt-5 grid gap-3 md:grid-cols-2">
        {review.sections.map((section) => (
          <div key={section.key} className={`rounded-xl border bg-white p-4 ${section.complete ? 'border-success-200' : 'border-warning-200'}`}>
            <div className="flex items-center justify-between gap-3">
              <p className="font-semibold text-neutral-900">{section.label}</p>
              <Badge variant={section.complete ? 'success' : 'warning'}>{section.complete ? 'Ready to review' : 'Incomplete'}</Badge>
            </div>
            <p className="mt-2 text-sm leading-6 text-neutral-600">{section.description}</p>
            {section.missing_required_fields.length > 0 && <p className="mt-2 text-xs font-semibold text-warning-800">Missing: {section.missing_required_fields.map((field) => field.replaceAll('_', ' ')).join(', ')}</p>}
          </div>
        ))}
      </div>
      <div className="mt-5 flex flex-wrap gap-2">
        <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to="/settings/clients">Review client information <ArrowRight className="h-4 w-4" /></Link>
        <Link className="inline-flex min-h-10 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to="/check-settings">Review check settings <ArrowRight className="h-4 w-4" /></Link>
      </div>
      {review.current ? (
        <div className="mt-5 rounded-xl border border-success-200 bg-success-50 p-4 text-sm text-success-800">
          <p className="font-semibold">Confirmed {review.reviewed_at ? formatGuamDateTime(review.reviewed_at) : ''}{review.reviewed_by_name ? ` by ${review.reviewed_by_name}` : ''}</p>
          {review.review_notes && <p className="mt-2 leading-6">{review.review_notes}</p>}
        </div>
      ) : (
        <div className="mt-5 grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(280px,0.65fr)]">
          <FieldTextarea label="Company setup review note" value={notes} onChange={onNotesChange} disabled={!canReview} required helperText="Record which employer document was checked and any remaining non-blocking follow-up." />
          <div>
            <Input label={`Type ${review.acknowledgement}`} value={acknowledgement} onChange={(event) => onAcknowledgementChange(event.target.value)} disabled={!canReview} />
            <Button className="mt-4" disabled={!canReview || review.missing_required_fields.length > 0 || !notes.trim() || acknowledgement !== review.acknowledgement || busy} onClick={onConfirm}>{busy ? 'Recording review…' : 'Mark company setup reviewed'}</Button>
          </div>
        </div>
      )}
    </div>
  );
}

function Guardrail({ icon, title, text }: { icon: ReactElement; title: string; text: string }): ReactElement {
  return <div className="rounded-2xl border border-neutral-200 bg-white p-5"><div className="flex items-center gap-2 font-semibold text-neutral-950">{icon}{title}</div><p className="mt-2 text-sm leading-6 text-neutral-600">{text}</p></div>;
}

function Metric({ label, value }: { label: string; value: string }): ReactElement {
  return <div className="rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3"><p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-neutral-500">{label}</p><p className="mt-1 text-lg font-bold text-neutral-950">{value}</p></div>;
}

function FieldSelect({ label, value, onChange, children, disabled, required }: { label: string; value: string; onChange: (value: string) => void; children: ReactNode; disabled?: boolean; required?: boolean }): ReactElement {
  return <label className="space-y-1.5"><span className="block text-sm font-medium text-neutral-700">{label}</span><select className="block w-full rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm text-neutral-900 shadow-sm focus:border-primary-400 focus:outline-none focus:ring-2 focus:ring-primary-200 disabled:bg-neutral-50" value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled} required={required}>{children}</select></label>;
}

function FieldTextarea({ label, value, onChange, disabled, required, helperText }: { label: string; value: string; onChange: (value: string) => void; disabled?: boolean; required?: boolean; helperText?: string }): ReactElement {
  return <label className="block space-y-1.5"><span className="block text-sm font-medium text-neutral-700">{label}</span><Textarea className="min-h-28 rounded-xl border-neutral-300 bg-white focus-visible:ring-primary-200" value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled} required={required} />{helperText && <span className="block text-sm text-neutral-500">{helperText}</span>}</label>;
}

function MessageList({ tone, title, messages }: { tone: 'danger' | 'warning' | 'neutral'; title: string; messages: string[] }): ReactElement {
  const styles = tone === 'danger' ? 'border-danger-200 bg-danger-50 text-danger-800' : tone === 'warning' ? 'border-warning-200 bg-warning-50 text-warning-800' : 'border-neutral-200 bg-neutral-50 text-neutral-700';
  return <div className={`rounded-2xl border p-5 ${styles}`}><p className="flex items-center gap-2 font-semibold"><AlertTriangle className="h-4 w-4" />{title}</p><ul className="mt-3 space-y-2 text-sm leading-6">{messages.map((message) => <li key={message}>• {message}</li>)}</ul></div>;
}

function ReadinessFact({ label, value, passed }: { label: string; value: boolean | number; passed: boolean }): ReactElement {
  return <div className={`flex items-center justify-between gap-4 rounded-xl border px-4 py-3 ${passed ? 'border-success-200 bg-success-50' : 'border-neutral-200 bg-white'}`}><span className="text-sm font-medium text-neutral-700">{label}</span><span className={`flex items-center gap-2 text-sm font-bold ${passed ? 'text-success-700' : 'text-neutral-600'}`}>{passed ? <CheckCircle2 className="h-4 w-4" /> : <CircleDashed className="h-4 w-4" />}{typeof value === 'boolean' ? (value ? 'Yes' : 'Not yet') : value}</span></div>;
}

function Comparison({ label, source, target }: { label: string; source: string | number; target: string | number }): ReactElement {
  return <div><p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">{label}</p><p className="mt-1 font-semibold text-neutral-900">QB {source}</p><p className="text-neutral-500">CP {target}</p></div>;
}

function Signoff({ title, signedAt, signedBy, acknowledgement, value, onChange, canSign, busy, onSign }: { title: string; signedAt?: string | null; signedBy?: string | null; acknowledgement: string; value: string; onChange: (value: string) => void; canSign: boolean; busy: boolean; onSign: () => void }): ReactElement {
  return <div className="rounded-2xl border border-neutral-200 p-5"><div className="flex items-center justify-between gap-3"><p className="font-semibold text-neutral-950">{title}</p>{signedAt && <Badge variant="success">Signed</Badge>}</div>{signedAt ? <p className="mt-3 text-sm leading-6 text-neutral-600">{signedBy || 'Authorized staff'} · {formatGuamDateTime(signedAt)}</p> : <><Input className="mt-4" label={`Type ${acknowledgement}`} value={value} onChange={(event) => onChange(event.target.value)} disabled={!canSign} /><Button className="mt-4" variant="outline" disabled={!canSign || busy || value !== acknowledgement} onClick={onSign}>{busy ? 'Signing…' : 'Sign'}</Button></>}</div>;
}
