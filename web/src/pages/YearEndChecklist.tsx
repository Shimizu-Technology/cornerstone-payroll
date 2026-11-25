import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import { Link, useParams, useSearchParams } from 'react-router';
import { AlertCircle, ArrowLeft, CheckCircle2, RefreshCw } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { useFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { FilingEvidencePanel } from '@/components/reports/FilingEvidencePanel';
import { EmployeeW2Copies } from '@/components/year-end/EmployeeW2Copies';
import { EmployerStep } from '@/components/year-end/EmployerStep';
import { FilingDecisionStep } from '@/components/year-end/FilingDecisionStep';
import { Form1099ReadyStep } from '@/components/year-end/Form1099ReadyStep';
import { MarkReadyStep } from '@/components/year-end/MarkReadyStep';
import { PeopleStep } from '@/components/year-end/PeopleStep';
import { PrintAndFileStep } from '@/components/year-end/PrintAndFileStep';
import { ReconciliationStep } from '@/components/year-end/ReconciliationStep';
import { ReviewWarningsStep } from '@/components/year-end/ReviewWarningsStep';
import { IssueList, StepCard } from '@/components/year-end/StepCard';
import { PayrollHistoryReview } from '@/components/year-end/PayrollHistoryReview';
import { useCompany } from '@/contexts/CompanyContext';
import { useOptionalSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { canWriteCompany } from '@/lib/company-write-access';
import { yearEndApi } from '@/services/api';
import { parsePositiveRouteId } from '@/lib/route-params';
import { yearEndPath } from '@/lib/routes';
import { clientStatusLabel, isActiveStep, parseYearEndTaxYear, yearEndTaxYears, type ActiveYearEndStep, type YearEndChecklist as Checklist, type YearEndStep } from '@/lib/year-end';

/**
 * 1099 filing evidence needs the 1099s marked ready on the current inputs,
 * as the server's recorder does. A year with no 1099 payee is done without
 * a sign-off, but has nothing to file, so the actions stay closed.
 */
function form1099ReadyStep(checklist: Checklist): ActiveYearEndStep<'form_1099_ready'> | undefined {
  const step = checklist.steps.find((entry) => entry.key === 'form_1099_ready');
  return step && step.key === 'form_1099_ready' && isActiveStep(step) ? step : undefined;
}

function form1099EvidenceReady(checklist: Checklist): boolean {
  const step = form1099ReadyStep(checklist);
  return step?.status === 'done' && step.data.payee_count > 0;
}

function form1099EvidenceMessage(checklist: Checklist): string {
  const step = form1099ReadyStep(checklist);
  if (step?.status === 'done' && step.data.payee_count === 0) return `No 1099s to file for ${checklist.tax_year}`;
  return 'Mark the 1099s ready above before recording the 1099 filing.';
}

function stepBody(checklist: Checklist, step: YearEndStep, onSaved: (message: string) => Promise<void>, onRefresh: () => Promise<void>): ReactElement | null {
  if (!isActiveStep(step)) return null;
  switch (step.key) {
    case 'filing_decision': return <FilingDecisionStep checklist={checklist} step={step} onSaved={onSaved} />;
    case 'employer': return <EmployerStep checklist={checklist} step={step} onSaved={onSaved} />;
    case 'people': return <PeopleStep checklist={checklist} step={step} onSaved={onSaved} onRefresh={onRefresh} />;
    case 'form_1099_ready': return <Form1099ReadyStep checklist={checklist} step={step} onSaved={onSaved} onRefresh={onRefresh} />;
    case 'reconciliation': return <ReconciliationStep step={step} taxYear={checklist.tax_year} />;
    case 'review_warnings': return <ReviewWarningsStep checklist={checklist} step={step} onSaved={onSaved} onRefresh={onRefresh} />;
    case 'prior_provider':
      return step.issues.length > 0 ? (
        <div>
          <IssueList issues={step.issues} />
          <p className="text-sm text-neutral-700">
            Check the date in <a href="#step-filing_decision" className="font-semibold text-primary-700 underline">step 1</a>. If the prior provider really files that period, the imported history for it must come out of this client's W-2 totals before they can be marked ready.
          </p>
        </div>
      ) : null;
    case 'mark_ready': return <MarkReadyStep checklist={checklist} step={step} onSaved={onSaved} />;
    case 'print_and_file': return <PrintAndFileStep checklist={checklist} step={step} />;
    default: return null;
  }
}

// Final copies open the step, including when marking ready on this page
// makes them final; drafts stay folded under the work still to do. The step
// stays mounted while folded so a download in progress still saves.
function finalDocumentsReady(step: YearEndStep): boolean {
  return step.key === 'print_and_file' && step.status === 'available' && step.data.final;
}

function StatusPanel({ checklist }: { checklist: Checklist }): ReactElement {
  const next = checklist.steps.find((step) => step.key === checklist.next_step);
  const ready = checklist.status === 'ready';
  const notFiling = checklist.status === 'not_filing';
  return (
    <Card className={ready ? 'border-success-200 bg-success-50/50' : notFiling ? 'bg-neutral-50' : 'border-warning-200 bg-warning-50/40'}>
      <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between sm:p-5">
        <div className="flex items-start gap-3">
          {ready ? <CheckCircle2 className="mt-0.5 h-6 w-6 shrink-0 text-success-700" aria-hidden="true" /> : <AlertCircle className="mt-0.5 h-6 w-6 shrink-0 text-warning-700" aria-hidden="true" />}
          <div>
            <p className="font-display text-xl font-extrabold text-neutral-950" aria-live="polite">{clientStatusLabel(checklist)}</p>
            <p className="text-sm text-neutral-700">
              {ready && `${checklist.company.name}'s ${checklist.tax_year} forms are ready to prepare.`}
              {notFiling && `Cornerstone files no ${checklist.tax_year} W-2s or 1099s for this client. Nothing was deleted.`}
              {!ready && !notFiling && next && `Next: step ${next.number}, ${next.title.toLowerCase()}.`}
            </p>
          </div>
        </div>
        {next && !ready && (
          <a
            href={`#step-${next.key}`}
            className="inline-flex min-h-11 items-center justify-center rounded-full bg-primary-700 px-4 py-2 text-sm font-semibold text-white hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
          >
            Go to step {next.number}
          </a>
        )}
      </div>
    </Card>
  );
}

export function YearEndChecklist(): ReactElement {
  const { companyId: companyIdParam } = useParams<{ companyId: string }>();
  const companyId = parsePositiveRouteId(companyIdParam) ?? 0;
  const { activeCompany } = useCompany();
  const canManageCopies = useOptionalSelectedCompanyCapability('manage_client_administration', companyId);
  const [searchParams, setSearchParams] = useSearchParams();
  const year = parseYearEndTaxYear(searchParams.get('year'));
  const [loaded, setChecklist] = useState<Checklist | null>(null);
  // Only the route's client and year are ever shown. A checklist still held
  // from the previous client or year unmounts its steps in the same render
  // as the switch, so a download or save they started can't land here, even
  // if React batches the clear below with the next load.
  const checklist = loaded && loaded.company.id === companyId && loaded.tax_year === year ? loaded : null;
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const { notify } = useFeedback();
  const requestId = useRef(0);
  // The client and year this page shows now. A load or save started for an
  // earlier one is dropped instead of replacing this page's checklist.
  const scope = `${companyId}:${year}`;
  const currentScope = useRef(scope);
  currentScope.current = scope;

  const load = useCallback(async () => {
    const loadScope = `${companyId}:${year}`;
    if (loadScope !== currentScope.current) return;
    const id = ++requestId.current;
    setLoading(true);
    setError(null);
    try {
      const response = await yearEndApi.checklist(year, companyId);
      if (id === requestId.current) setChecklist(response.data);
    } catch (err) {
      if (id === requestId.current) setError(err instanceof Error ? err.message : 'The checklist could not be loaded.');
    } finally {
      if (id === requestId.current) setLoading(false);
    }
  }, [companyId, year]);

  useEffect(() => {
    setChecklist(null);
    void load();
  }, [load]);

  const onSaved = useCallback(async (message: string) => {
    if (`${companyId}:${year}` !== currentScope.current) return;
    notify({ tone: 'success', message });
    await load();
  }, [companyId, load, notify, year]);

  // Reloads this client and year only; a refresh asked for on an earlier
  // one is dropped like a save.
  const onRefresh = useCallback(async () => {
    if (`${companyId}:${year}` !== currentScope.current) return;
    await load();
  }, [companyId, load, year]);

  return (
    <div>
      <Header
        title={`${year} year-end checklist`}
        description="Work down the steps in order. Each one says what is wrong and how to fix it."
        mobileSticky={false}
        actions={(
          <div className="flex items-end gap-2">
            <Link
              to={yearEndPath(year)}
              className="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-full border border-neutral-300 bg-white px-4 py-2 text-sm font-semibold text-neutral-800 sm:flex-none hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300"
            >
              <ArrowLeft className="h-4 w-4" aria-hidden="true" />All clients
            </Link>
            <div className="w-28">
              <Select
                label="Tax year"
                value={String(year)}
                onChange={(event) => setSearchParams({ year: event.target.value })}
                className="min-h-11"
              >
                {yearEndTaxYears().map((option) => <option key={option} value={option}>{option}</option>)}
              </Select>
            </div>
          </div>
        )}
      />

      <div className="mx-auto max-w-6xl space-y-4 p-4 sm:p-6 lg:p-8">
        {error && (
          <Card role="alert" className="border-danger-200 bg-danger-50/40 p-4 sm:p-5">
            <p className="font-semibold text-danger-800">The checklist could not be loaded.</p>
            <p className="mt-1 text-sm text-danger-700">{error}</p>
            <Button size="sm" variant="outline" className="mt-3" onClick={() => void load()}>
              <RefreshCw className="mr-1.5 h-4 w-4" aria-hidden="true" />Try again
            </Button>
          </Card>
        )}

        {loading && !checklist && (
          <div className="space-y-3" role="status" aria-label="Loading checklist">
            {[0, 1, 2, 3].map((index) => <div key={index} className="h-20 animate-pulse rounded-2xl bg-neutral-100" />)}
          </div>
        )}

        {checklist && (
          <>
            <StatusPanel checklist={checklist} />
            <ol className="space-y-3" aria-busy={loading || undefined}>
              {checklist.steps.map((step) => (
                // Scoped by client and year: a new client or year always remounts each step.
                <li key={`${checklist.company.id}:${checklist.tax_year}-${step.key}-${step.status}`}>
                  <StepCard
                    step={step}
                    isNext={checklist.next_step === step.key}
                    defaultOpen={finalDocumentsReady(step)}
                    keepMounted={step.key === 'print_and_file'}
                  >
                    {stepBody(checklist, step, onSaved, onRefresh)}
                  </StepCard>
                </li>
              ))}
            </ol>

            {(checklist.files_w2 || checklist.files_1099) && (
              <Card>
                <CardHeader className="flex-row items-start gap-3 space-y-0">
                  {/* Numbered like the step cards above: filing comes after the last step. */}
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-neutral-100 text-sm font-bold text-neutral-700" aria-hidden="true">
                    {checklist.steps.length + 1}
                  </span>
                  <div className="min-w-0 flex-1">
                    <CardTitle className="text-base"><span className="sr-only">Step {checklist.steps.length + 1}: </span>File and confirm</CardTitle>
                    <CardDescription>After you file outside the app, keep the receipt and the agency's result here.</CardDescription>
                  </div>
                </CardHeader>
                <CardContent className="space-y-6">
                  {checklist.files_w2 && ((checklist.tax_year >= 2026 ? ['ssa', 'drt'] : [undefined]).map((agency) => (
                    <FilingEvidencePanel
                      key={agency ?? 'receipt'}
                      {...(agency ? { agency } : {})}
                      filingType="w2_gu_w3_ss"
                      taxYear={checklist.tax_year}
                      companyId={checklist.company.id}
                      preparationReady={checklist.steps.some((step) => step.key === 'mark_ready' && step.status === 'done')}
                      readinessMessage="Mark the W-2s ready above before recording delivery to SSA or DRT."
                    />
                  )))}
                  {checklist.files_1099 && (
                    <FilingEvidencePanel
                      filingType="form_1099_nec"
                      agency="drt"
                      taxYear={checklist.tax_year}
                      companyId={checklist.company.id}
                      preparationReady={form1099EvidenceReady(checklist)}
                      readinessMessage={form1099EvidenceMessage(checklist)}
                    />
                  )}
                </CardContent>
              </Card>
            )}

            <p className="pt-2 text-sm font-semibold text-neutral-700">Also for this year</p>
            {canManageCopies && (
              <EmployeeW2Copies key={`w2-copies:${scope}`} companyId={companyId} companyName={checklist.company.name} year={year}
                canWrite={canWriteCompany(activeCompany, 'manage_client_administration')} checklistLoading={loading} />
            )}

            <PayrollHistoryReview key={`payroll-history:${scope}`} companyId={companyId} year={year} onSaved={onSaved} onRefresh={onRefresh} />
          </>
        )}
      </div>
    </div>
  );
}
