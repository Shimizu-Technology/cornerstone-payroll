import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router";
import { AlertTriangle, Check, CheckCircle2, ChevronDown, ChevronRight, CircleDashed, FileDown, Plus, ShieldCheck, Trash2 } from "lucide-react";
import { Header } from "@/components/layout/Header";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { useAuth } from "@/contexts/AuthContext";
import { useCompany } from "@/contexts/CompanyContext";
import { ApiError } from "@/services/api";
import {
  amountLabels,
  breakdownLabels,
  priorProviderHistoryApi,
  registerLabels,
  type AmountKey,
  type BreakdownKey,
  type HistoryCheck,
  type HistoryEmployee,
  type HistoryOnboarding,
  type HistoryPage,
  type HistoryPayload,
  type HistoryPeriod,
  type HistoryPreview,
} from "@/services/priorProviderHistory";
import {
  REGISTER_KEYS,
  decimal,
  emptyCheck,
  employeeIds,
  employeeTotals,
  identityConfirmed,
  initialPayload,
  money,
  normalizeCandidate,
  paycheckProblems,
  periodLabel,
  periodState,
  periodTotals,
  registerDifferences,
  remainingWork,
  setPaycheckAmount,
  shortDate,
  signedMoney,
  takeoverQuarter,
  type EmployeeTotals,
  type PeriodState,
} from "./prior-provider/historyModel";

// The server keeps these phrases as its audit acknowledgement; people confirm
// through a summary dialog and checkbox instead of typing them.
const RECORD_ACK = "RECORD ALREADY PAID HISTORY";
const ACTIVATE_ACK = "ACTIVATE VERIFIED HISTORICAL YTD";
const REVERSE_ACK = "REVERSE PRIOR PROVIDER HISTORY";
const STEPS = ["Pay dates", "Employees", "Match registers", "Record", "Turn on YTD"];
const MAIN_COLUMNS: AmountKey[] = ["gross_pay", "federal_income_tax", "social_security_tax", "medicare_tax", "pretax_deductions", "after_tax_deductions", "net_pay"];
const SHORT: Partial<Record<AmountKey, string>> = {
  gross_pay: "Gross",
  federal_income_tax: "Income tax",
  social_security_tax: "Social Security",
  medicare_tax: "Medicare",
  pretax_deductions: "Pre-tax deductions",
  after_tax_deductions: "Post-tax deductions",
  net_pay: "Net pay",
};
const WAGE_COLUMNS: AmountKey[] = ["fit_taxable_wages", "social_security_taxable_wages", "social_security_taxable_tips", "medicare_taxable_wages", "additional_medicare_taxable_wages"];
const EMPLOYER_COLUMNS: AmountKey[] = ["employer_social_security_tax", "employer_medicare_tax", "employer_contributions"];
const OTHER_COLUMNS: AmountKey[] = ["non_taxable_pay", "reported_tips", "tips_paid_out", "retirement", "roth_retirement", "insurance", "loans"];
const AUTOSAVE_MS = 1200;

type SaveState = "idle" | "saving" | "saved" | "unsaved" | "conflict" | "error";

export function PriorProviderHistory() {
  const { activeCompanyId } = useCompany();
  const { user } = useAuth();
  return <HistoryWorkspace key={`${user?.id}:${activeCompanyId}`} companyId={activeCompanyId} userId={user?.id} />;
}

function HistoryWorkspace({ companyId, userId }: { companyId: number | null; userId?: number }) {
  const [page, setPage] = useState<HistoryPage | null>(null);
  const [payload, setPayload] = useState<HistoryPayload | null>(null);
  const [step, setStep] = useState(0);
  const [version, setVersion] = useState<number | undefined>(undefined);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [savedAt, setSavedAt] = useState<string>("");
  const [files, setFiles] = useState<File[]>([]);
  const [preview, setPreview] = useState<HistoryPreview | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [dialog, setDialog] = useState<"record" | "activate" | "reverse" | "discard" | null>(null);
  const mounted = useRef(true);
  const dirty = useRef(false);
  const requestBusy = useRef(false);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const load = useCallback(async () => {
    try {
      const result = await priorProviderHistoryApi.get();
      if (!mounted.current || result.company_id !== companyId) return;
      setPage(result);
      setPayload(initialPayload(result));
      setStep(result.draft?.step ?? 0);
      setVersion(result.draft?.lock_version);
      setSavedAt(result.draft ? `${new Date(result.draft.updated_at).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })} by ${result.draft.updated_by_name}` : "");
      setSaveState(result.draft ? "saved" : "idle");
      dirty.current = false;
    } catch (err) {
      if (mounted.current) setError(err instanceof Error ? err.message : "Couldn’t load this client’s history. Try again.");
    }
  }, [companyId]);

  useEffect(() => {
    void load();
  }, [load]);

  const canManage = page?.can_manage === true;
  const active = page?.onboardings.find((record) => record.status !== "reversed");

  const save = useCallback(async () => {
    if (!payload || !canManage || active) return;
    setSaveState("saving");
    dirty.current = false;
    try {
      const result = await priorProviderHistoryApi.saveDraft(payload, Math.min(step, 3), version);
      if (!mounted.current) return;
      setVersion(result.draft.lock_version);
      setSavedAt(new Date(result.draft.updated_at).toLocaleTimeString("en-US", { timeStyle: "short" }));
      setSaveState(dirty.current ? "unsaved" : "saved");
    } catch (err) {
      if (!mounted.current) return;
      if (err instanceof ApiError && err.status === 409) {
        setSaveState("conflict");
        setError(err.message);
      } else {
        dirty.current = true;
        setSaveState("error");
      }
    }
  }, [payload, step, version, canManage, active]);

  // Autosave quietly after edits so work can be resumed at any step.
  useEffect(() => {
    if (!dirty.current || saveState === "conflict" || saveState === "saving") return;
    const timer = window.setTimeout(() => void save(), AUTOSAVE_MS);
    return () => window.clearTimeout(timer);
  }, [payload, step, save, saveState]);

  const update = (next: HistoryPayload) => {
    setPayload(next);
    setPreview(null);
    dirty.current = true;
    if (saveState !== "conflict" && saveState !== "saving") setSaveState("unsaved");
  };
  const goTo = (index: number) => {
    setStep(index);
    dirty.current = true;
    if (saveState === "saved" || saveState === "idle") setSaveState("unsaved");
    window.scrollTo?.({ top: 0 });
  };

  const perform = async (operation: () => Promise<void>) => {
    if (requestBusy.current) return;
    requestBusy.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await operation();
    } catch (err) {
      if (mounted.current) setError(err instanceof Error ? err.message : "That didn’t save. Try again.");
    } finally {
      requestBusy.current = false;
      if (mounted.current) setBusy(false);
    }
  };

  const download = async (record: HistoryOnboarding, file: HistoryOnboarding["source_files"][number]) =>
    perform(async () => {
      const blob = await priorProviderHistoryApi.sourceFile(record.id, file.id);
      if (!mounted.current) return;
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = file.original_filename;
      link.click();
      URL.revokeObjectURL(url);
    });

  const remaining = page && payload ? remainingWork(payload, page.employees, files.length > 0) : [];

  return (
    <>
      <Header
        title="Prior-provider history"
        subtitle="Record payroll the previous provider already paid this year, so year-to-date totals and year-end forms include it."
        mobileSticky={false}
        actions={
          <Link className="inline-flex min-h-11 items-center text-sm font-semibold text-primary-700 underline sm:min-h-0" to="/settings/clients">
            Back to clients
          </Link>
        }
      />
      <main className="mx-auto w-full max-w-6xl space-y-5 p-4 sm:p-6 lg:p-8">
        {error && (
          <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">
            <span className="min-w-0">{error}</span>
            <Button variant="outline" size="sm" onClick={() => { setError(""); void load(); }}>
              {saveState === "conflict" ? "Load the latest version" : "Reload"}
            </Button>
          </div>
        )}
        {notice && (
          <p role="status" className="rounded-xl border border-success-200 bg-success-50 p-4 text-sm text-success-800">
            {notice}
          </p>
        )}
        {!page || !payload ? (
          <p role="status" className="text-sm text-neutral-600">Loading history…</p>
        ) : (
          <>
            {!canManage && (
              <p className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm">
                View only. Payroll staff with access to this client can record its history.
              </p>
            )}
            <StepIndicator
              step={active ? 4 : step}
              done={stepDone(payload, page.employees, files.length > 0, active)}
              locked={Boolean(active)}
              onSelect={goTo}
            />
            {active ? (
              <SavedHistory
                record={active}
                employees={page.employees}
                companyId={companyId}
                canManage={canManage}
                busy={busy}
                onDownload={download}
                readinessGaps={page.readiness_gaps ?? []}
                onActivate={() => setDialog("activate")}
                onReverse={() => setDialog("reverse")}
              />
            ) : (
              <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_17rem]">
                <section className="min-w-0 space-y-5 rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6" aria-labelledby="history-step-title">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <h2 id="history-step-title" className="text-lg font-semibold">
                      {step + 1}. {STEPS[step]}
                    </h2>
                    {canManage && <SaveStatus state={saveState} savedAt={savedAt} onSave={() => void save()} />}
                  </div>
                  <fieldset disabled={!canManage || busy} className="min-w-0 space-y-5">
                    {step === 0 && <PayDatesStep page={page} payload={payload} onChange={update} />}
                    {step === 1 && <EmployeesStep employees={page.employees} payload={payload} onChange={update} />}
                    {step === 2 && <RegistersStep employees={page.employees} payload={payload} onChange={update} />}
                    {step === 3 && (
                      <RecordStep
                        payload={payload}
                        files={files}
                        preview={preview}
                        onFiles={(next) => { setFiles(next); setPreview(null); }}
                        onChange={update}
                        onGoTo={goTo}
                        onCheck={() =>
                          void perform(async () => {
                            const result = await priorProviderHistoryApi.preview(payload);
                            if (mounted.current) setPreview(result);
                          })
                        }
                        onRecord={() => setDialog("record")}
                        remaining={remaining}
                      />
                    )}
                  </fieldset>
                  <div className="flex flex-wrap justify-between gap-3 border-t border-neutral-100 pt-4">
                    <Button variant="outline" disabled={step === 0} onClick={() => goTo(step - 1)}>
                      Back
                    </Button>
                    {step < 3 && <Button onClick={() => goTo(step + 1)}>Continue to {STEPS[step + 1].toLowerCase()}</Button>}
                  </div>
                </section>
                <aside className="space-y-4 lg:sticky lg:top-4 lg:self-start" aria-label="What’s left">
                  <div className="rounded-2xl border border-neutral-200 bg-white p-4">
                    <h2 className="text-sm font-semibold">What’s left</h2>
                    {remaining.length === 0 ? (
                      <p className="mt-2 flex items-center gap-2 text-sm text-success-800">
                        <CheckCircle2 className="h-4 w-4" aria-hidden /> Ready to record
                      </p>
                    ) : (
                      <ul className="mt-2 space-y-1">
                        {remaining.map((item) => (
                          <li key={item.text}>
                            <button type="button" className="flex min-h-11 w-full items-start gap-2 rounded-lg px-1 py-1.5 text-left text-sm text-neutral-700 hover:bg-neutral-50 sm:min-h-0" onClick={() => goTo(item.step)}>
                              <CircleDashed className="mt-0.5 h-4 w-4 shrink-0 text-neutral-400" aria-hidden />
                              <span>{item.text}</span>
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                  <div className="flex items-start gap-2 rounded-2xl border border-primary-100 bg-primary-50 p-4 text-xs leading-5 text-primary-900">
                    <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                    <p>Recording history creates no checks, payments, deposits or emails. You can undo it until the first live payroll is committed.</p>
                  </div>
                  {canManage && (page.draft || saveState === "saved") && (
                    <Button variant="ghost" size="sm" onClick={() => setDialog("discard")}>
                      <Trash2 className="mr-2 h-4 w-4" aria-hidden /> Discard saved progress
                    </Button>
                  )}
                </aside>
              </div>
            )}
            {page.onboardings
              .filter((record) => record.status === "reversed")
              .map((record) => (
                <details key={record.id} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm">
                  <summary className="cursor-pointer font-semibold">
                    Undone history · {record.provider_name} · {record.tax_year}
                  </summary>
                  <p className="my-3">
                    {record.reversal_reason} · {record.reversed_at ? new Date(record.reversed_at).toLocaleString() : ""}
                  </p>
                  {record.source_files.map((file) => (
                    <Button key={file.id} variant="outline" size="sm" className="mb-2 mr-2" onClick={() => void download(record, file)}>
                      <FileDown className="mr-2 h-4 w-4" aria-hidden />
                      {file.original_filename}
                    </Button>
                  ))}
                </details>
              ))}
            <RecordDialog
              open={dialog === "record"}
              payload={payload}
              employees={page.employees}
              files={files}
              busy={busy}
              onClose={() => setDialog(null)}
              onConfirm={() =>
                void perform(async () => {
                  if (!preview?.ready) return;
                  const requestKey = `prior-provider-history:${userId}:${companyId}:request:${preview.digest}`;
                  const key = sessionStorage.getItem(requestKey) || crypto.randomUUID();
                  sessionStorage.setItem(requestKey, key);
                  await priorProviderHistoryApi.convert(payload, preview.digest, key, files, RECORD_ACK);
                  sessionStorage.removeItem(requestKey);
                  if (!mounted.current) return;
                  setDialog(null);
                  setNotice("History recorded. Review it below, then turn on year-to-date totals.");
                  await load();
                })
              }
            />
            {active && (
              <>
                <ActivateDialog
                  open={dialog === "activate"}
                  record={active}
                  employees={page.employees}
                  busy={busy}
                  onClose={() => setDialog(null)}
                  onConfirm={() =>
                    void perform(async () => {
                      await priorProviderHistoryApi.activate(active.id, ACTIVATE_ACK);
                      if (!mounted.current) return;
                      setDialog(null);
                      setNotice("Year-to-date totals are on. Start the first Cornerstone payroll after the last recorded pay date.");
                      await load();
                    })
                  }
                />
                <ReverseDialog
                  open={dialog === "reverse"}
                  busy={busy}
                  onClose={() => setDialog(null)}
                  onConfirm={(reason) =>
                    void perform(async () => {
                      await priorProviderHistoryApi.reverse(active.id, reason, REVERSE_ACK);
                      if (!mounted.current) return;
                      setDialog(null);
                      setNotice("History undone. The original pay dates are back and still marked as paid by the previous provider; record them again before running live payroll.");
                      await load();
                    })
                  }
                />
              </>
            )}
            <Dialog open={dialog === "discard"} onOpenChange={(open) => !busy && setDialog(open ? "discard" : null)}>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>Discard saved progress?</DialogTitle>
                  <DialogDescription>This clears the saved selections, confirmations and corrections for everyone working on this client. Nothing was recorded yet, so payroll is unchanged.</DialogDescription>
                </DialogHeader>
                <DialogFooter>
                  <Button variant="outline" onClick={() => setDialog(null)}>Keep progress</Button>
                  <Button
                    variant="danger"
                    loading={busy}
                    onClick={() =>
                      void perform(async () => {
                        await priorProviderHistoryApi.discardDraft();
                        if (!mounted.current) return;
                        setDialog(null);
                        setFiles([]);
                        await load();
                      })
                    }
                  >
                    Discard
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          </>
        )}
      </main>
    </>
  );
}

function stepDone(payload: HistoryPayload, employees: HistoryEmployee[], filesAttached: boolean, active?: HistoryOnboarding): boolean[] {
  if (active) return [true, true, true, true, active.status === "active"];
  const left = remainingWork(payload, employees, filesAttached);
  return [0, 1, 2, 3, 4].map((index) => index < 4 && !left.some((item) => item.step === index));
}

function StepIndicator({ step, done, locked, onSelect }: { step: number; done: boolean[]; locked: boolean; onSelect: (index: number) => void }) {
  return (
    <nav aria-label="Steps">
      <ol className="flex gap-1.5 overflow-x-auto pb-1 sm:grid sm:grid-cols-5 sm:overflow-visible">
        {STEPS.map((label, index) => {
          const current = step === index;
          const selectable = !locked && index < 4;
          const content = (
            <>
              <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${done[index] ? "bg-success-600 text-white" : current ? "bg-primary-700 text-white" : "bg-neutral-100 text-neutral-600"}`}>
                {done[index] ? <Check className="h-3.5 w-3.5" aria-hidden /> : index + 1}
              </span>
              <span className={`whitespace-nowrap ${current ? "" : "sr-only sm:not-sr-only"}`}>{label}</span>
              {done[index] && <span className="sr-only">(done)</span>}
            </>
          );
          const classes = `flex min-h-11 w-full items-center gap-2 rounded-xl border px-3 py-2 text-sm sm:min-h-0 ${current ? "border-primary-300 bg-primary-50 font-semibold text-primary-900" : "border-neutral-200 bg-white text-neutral-700"}`;
          return (
            <li key={label} className="shrink-0 sm:shrink">
              {selectable ? (
                <button type="button" aria-current={current ? "step" : undefined} className={`${classes} hover:border-primary-200`} onClick={() => onSelect(index)}>
                  {content}
                </button>
              ) : (
                <span aria-current={current ? "step" : undefined} className={classes}>
                  {content}
                </span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

function SaveStatus({ state, savedAt, onSave }: { state: SaveState; savedAt: string; onSave: () => void }) {
  const text =
    state === "saving" ? "Saving…" : state === "saved" ? `Saved${savedAt ? ` ${savedAt}` : ""}` : state === "error" ? "Not saved" : state === "conflict" ? "Someone else saved newer changes" : state === "unsaved" ? "Unsaved changes" : "Nothing saved yet";
  return (
    <div className="flex items-center gap-2 text-xs text-neutral-600" aria-live="polite">
      <span>{text}</span>
      {(state === "unsaved" || state === "error" || state === "idle") && (
        <Button variant="outline" size="sm" onClick={onSave}>
          {state === "error" ? "Retry save" : "Save progress"}
        </Button>
      )}
    </div>
  );
}

function PayDatesStep({ page, payload, onChange }: { page: HistoryPage; payload: HistoryPayload; onChange: (next: HistoryPayload) => void }) {
  const selected = new Set(payload.periods.map((period) => period.key));
  const candidateKeys = new Set(page.candidates.map((candidate) => candidate.key));
  const allSelected = page.candidates.length > 0 && page.candidates.every((candidate) => selected.has(candidate.key));
  const unavailable = payload.periods.filter((period) => period.run_id && !candidateKeys.has(period.key));
  const totals = payload.periods.reduce((sum, period) => sum.plus(decimal(periodTotals(period).gross_pay)), decimal("0"));
  const addManual = () =>
    onChange({
      ...payload,
      periods: [
        ...payload.periods,
        {
          key: `manual-${crypto.randomUUID()}`,
          start_date: "",
          end_date: "",
          pay_date: "",
          source_reference: "",
          register_totals: {},
          paychecks: page.employees[0] ? [emptyCheck(page.employees[0])] : [],
        },
      ],
    });
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Input label="Previous payroll provider" placeholder="For example, ADP" value={payload.provider_name} onChange={(e) => onChange({ ...payload, provider_name: e.target.value })} />
        <Input
          label="Cornerstone takes over on"
          type="date"
          helperText={`History covers ${payload.tax_year} pay dates before this date.`}
          value={payload.takeover_on}
          onChange={(e) => onChange({ ...payload, takeover_on: e.target.value, tax_year: Number(e.target.value.slice(0, 4)) || payload.tax_year })}
        />
      </div>
      <p className="text-sm leading-6 text-neutral-600">
        These are the payroll runs already entered here for this year. They’re selected for you; untick any that the previous provider didn’t pay.
      </p>
      {page.candidates_overflow && (
        <p role="alert" className="rounded-lg bg-warning-50 p-3 text-sm text-warning-900">
          Showing {page.candidates.length} of {page.eligible_run_count} runs. One year can include up to 60 pay dates; ask an administrator to review the extra runs first.
        </p>
      )}
      {page.candidates.length > 0 && (
        <div className="overflow-hidden rounded-xl border border-neutral-200">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-neutral-100 bg-neutral-50 px-3 py-2 text-sm">
            <span className="font-semibold">
              {payload.periods.length} pay {payload.periods.length === 1 ? "date" : "dates"} · {payload.periods.reduce((sum, period) => sum + period.paychecks.length, 0)} paychecks · {money(totals)} gross
            </span>
            <Button
              variant="ghost"
              size="sm"
              onClick={() =>
                onChange({
                  ...payload,
                  periods: allSelected
                    ? payload.periods.filter((period) => !period.run_id)
                    : [...page.candidates.map((candidate) => payload.periods.find((p) => p.key === candidate.key) ?? normalizeCandidate(candidate)), ...payload.periods.filter((p) => !p.run_id)],
                })
              }
            >
              {allSelected ? "Clear all" : `Select all (${page.candidates.length})`}
            </Button>
          </div>
          <ul className="divide-y divide-neutral-100">
            {page.candidates.map((period) => (
              <li key={period.key}>
                <label className="flex min-h-11 cursor-pointer items-center gap-3 px-3 py-2.5 text-sm hover:bg-neutral-50">
                  <input
                    className="h-4 w-4 shrink-0"
                    type="checkbox"
                    checked={selected.has(period.key)}
                    onChange={(e) =>
                      onChange({
                        ...payload,
                        periods: e.target.checked
                          ? [...payload.periods, normalizeCandidate(period)].sort((a, b) => a.pay_date.localeCompare(b.pay_date))
                          : payload.periods.filter((p) => p.key !== period.key),
                      })
                    }
                  />
                  <span className="min-w-0 flex-1">
                    <span className="font-semibold">Paid {shortDate(period.pay_date)}</span>
                    <span className="block text-neutral-600 sm:inline sm:before:content-['_·_']">{periodLabel(period)}</span>
                  </span>
                  <span className="shrink-0 tabular-nums text-neutral-700">{money(period.calculated_totals?.gross_pay)}</span>
                </label>
              </li>
            ))}
          </ul>
        </div>
      )}
      {unavailable.length > 0 && (
        <div role="alert" className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-warning-50 p-3 text-sm text-warning-900">
          <span>{unavailable.length} saved pay {unavailable.length === 1 ? "date is" : "dates are"} no longer available here (the run changed or was removed).</span>
          <Button variant="outline" size="sm" onClick={() => onChange({ ...payload, periods: payload.periods.filter((period) => !unavailable.includes(period)) })}>
            Remove {unavailable.length === 1 ? "it" : "them"}
          </Button>
        </div>
      )}
      {!page.candidates.length && <p className="text-sm text-neutral-600">No payroll runs are waiting here. Add each pay date from the provider’s registers.</p>}
      {payload.periods.filter((period) => !period.run_id).length > 0 && (
        <p className="text-sm text-neutral-700">{payload.periods.filter((period) => !period.run_id).length} pay date(s) added by hand — enter their dates and paychecks in Match registers.</p>
      )}
      <Button variant="outline" disabled={!page.employees.length} onClick={addManual}>
        <Plus className="mr-2 h-4 w-4" aria-hidden />
        Add a pay date that isn’t listed
      </Button>
    </>
  );
}

function EmployeesStep({ employees, payload, onChange }: { employees: HistoryEmployee[]; payload: HistoryPayload; onChange: (next: HistoryPayload) => void }) {
  const ids = employeeIds(payload);
  return (
    <>
      <p className="text-sm leading-6 text-neutral-600">Check that each person on the provider’s register is the same employee here. Nobody is added or removed.</p>
      <ul className="space-y-2">
        {ids.map((id) => {
          const employee = employees.find((row) => row.id === id);
          const confirmed = identityConfirmed(payload, employee);
          return (
            <li key={id} className={`flex flex-wrap items-center justify-between gap-3 rounded-xl border p-3 ${confirmed ? "border-success-200 bg-success-50/50" : "border-neutral-200"}`}>
              <div className="min-w-0">
                <p className="font-semibold">{employee?.name ?? `Employee ${id}`}</p>
                <p className="text-sm text-neutral-600">{employee?.ssn_last_four ? `SSN ending ${employee.ssn_last_four}` : "No SSN on file — add it to the employee profile first"}</p>
              </div>
              <label className="flex min-h-11 items-center gap-2 text-sm font-medium sm:min-h-0">
                <input
                  type="checkbox"
                  className="h-4 w-4"
                  disabled={!employee?.ssn_last_four}
                  checked={confirmed}
                  onChange={(e) => {
                    const identities = { ...payload.identities };
                    if (e.target.checked && employee?.ssn_last_four) identities[id] = { source_name: employee.name, ssn_last4: employee.ssn_last_four };
                    else delete identities[id];
                    onChange({ ...payload, identities });
                  }}
                />
                Matches the register
              </label>
            </li>
          );
        })}
      </ul>
      <p className="text-xs text-neutral-500">If a name or SSN is different on the register, correct the employee profile, then come back.</p>
    </>
  );
}

const STATE_BADGE: Record<PeriodState, { label: string; variant: "success" | "warning" | "danger" | "default" }> = {
  matched: { label: "Matches", variant: "success" },
  difference: { label: "Doesn’t match", variant: "danger" },
  problem: { label: "Needs a fix", variant: "danger" },
  to_check: { label: "To check", variant: "default" },
};

function RegistersStep({ employees, payload, onChange }: { employees: HistoryEmployee[]; payload: HistoryPayload; onChange: (next: HistoryPayload) => void }) {
  const firstOpen = payload.periods.findIndex((period) => periodState(period) !== "matched");
  const [open, setOpen] = useState<number | null>(firstOpen >= 0 ? firstOpen : null);
  const [reference, setReference] = useState("");
  const updatePeriod = (index: number, period: HistoryPeriod) => onChange({ ...payload, periods: payload.periods.map((old, i) => (i === index ? period : old)) });
  const matched = payload.periods.filter((period) => periodState(period) === "matched").length;
  return (
    <>
      <p className="text-sm leading-6 text-neutral-600">
        Open each pay date next to the provider’s paper or PDF register. The amounts are filled in from the saved payroll — correct anything that’s different, then mark it as matching.
      </p>
      <div className="flex flex-wrap items-end gap-3 rounded-xl bg-neutral-50 p-3">
        <div className="min-w-[14rem] flex-1">
          <Input label="Register name (fills every pay date)" placeholder="For example, ADP payroll register 2026" value={reference} onChange={(e) => setReference(e.target.value)} />
        </div>
        <Button
          variant="outline"
          disabled={!reference.trim()}
          onClick={() => onChange({ ...payload, periods: payload.periods.map((period) => (period.source_reference.trim() ? period : { ...period, source_reference: `${reference.trim()} — paid ${period.pay_date || "date"}` })) })}
        >
          Fill blank references
        </Button>
      </div>
      <p className="text-sm font-semibold">
        {matched} of {payload.periods.length} pay dates match
      </p>
      <ul className="space-y-2">
        {payload.periods.map((period, index) => {
          const state = periodState(period);
          const expanded = open === index;
          const totals = periodTotals(period);
          return (
            <li key={period.key} className={`rounded-xl border ${expanded ? "border-primary-200" : "border-neutral-200"}`}>
              <button
                type="button"
                aria-expanded={expanded}
                className="flex min-h-11 w-full items-center gap-3 px-3 py-2.5 text-left text-sm"
                onClick={() => setOpen(expanded ? null : index)}
              >
                {expanded ? <ChevronDown className="h-4 w-4 shrink-0" aria-hidden /> : <ChevronRight className="h-4 w-4 shrink-0" aria-hidden />}
                <span className="min-w-0 flex-1">
                  <span className="block font-semibold sm:inline">{period.pay_date ? `Paid ${shortDate(period.pay_date)}` : "New pay date"}</span>
                  <span className="block text-neutral-600 sm:ml-2 sm:inline">
                    {period.start_date && periodLabel(period)}
                    <span className="tabular-nums sm:hidden"> · {money(totals.gross_pay)}</span>
                  </span>
                </span>
                <span className="hidden tabular-nums text-neutral-700 sm:inline">{money(totals.gross_pay)}</span>
                <Badge variant={STATE_BADGE[state].variant}>{STATE_BADGE[state].label}</Badge>
              </button>
              {expanded && (
                <PeriodEditor
                  period={period}
                  employees={employees}
                  onChange={(next) => updatePeriod(index, next)}
                  onRemove={() => {
                    onChange({ ...payload, periods: payload.periods.filter((_, i) => i !== index) });
                    setOpen(null);
                  }}
                  onMatched={(next) => {
                    const periods = payload.periods.map((old, i) => (i === index ? next : old));
                    onChange({ ...payload, periods });
                    const following = periods.findIndex((candidate, i) => i > index && periodState(candidate) !== "matched");
                    setOpen(following >= 0 ? following : null);
                  }}
                />
              )}
            </li>
          );
        })}
      </ul>
    </>
  );
}

function PeriodEditor({
  period,
  employees,
  onChange,
  onRemove,
  onMatched,
}: {
  period: HistoryPeriod;
  employees: HistoryEmployee[];
  onChange: (period: HistoryPeriod) => void;
  onRemove: () => void;
  onMatched: (period: HistoryPeriod) => void;
}) {
  const totals = periodTotals(period);
  const differences = registerDifferences(period);
  const [enterTotals, setEnterTotals] = useState(Object.keys(differences).length > 0);
  const problems = period.paychecks.map(paycheckProblems);
  const hasProblems = problems.some((row) => Object.keys(row).length > 0);
  const changeCheck = (rowIndex: number, next: HistoryCheck) =>
    onChange({ ...period, paychecks: period.paychecks.map((row, i) => (i === rowIndex ? next : row)), register_totals: enterTotals ? period.register_totals : {} });
  const confirmMatch = () => onMatched({ ...period, register_totals: { ...totals } });
  const manual = !period.run_id;
  return (
    <div className="space-y-4 border-t border-neutral-100 p-3 sm:p-4">
      {manual && (
        <div className="grid gap-3 sm:grid-cols-3">
          {(["start_date", "end_date", "pay_date"] as const).map((key) => (
            <Input key={key} label={key === "start_date" ? "Period start" : key === "end_date" ? "Period end" : "Pay date"} type="date" value={period[key]} onChange={(e) => onChange({ ...period, [key]: e.target.value })} />
          ))}
        </div>
      )}
      <Input
        label="Where this is on the register"
        placeholder="For example, page 3"
        value={period.source_reference}
        error={period.source_reference.trim() ? undefined : "Needed: a page or file reference for this pay date"}
        onChange={(e) => onChange({ ...period, source_reference: e.target.value })}
      />
      <div className="space-y-2">
        <p className="text-xs text-neutral-600">Check numbers are optional. Enter the previous provider’s numbers, including any leading zeros. These never use Cornerstone’s check sequence.</p>
        <table className="w-full text-left text-sm">
          <caption className="sr-only">Previous provider’s checks for this pay date</caption>
          <thead><tr><th scope="col" className="w-1/2 py-2 pr-3">Employee</th><th scope="col" className="py-2">Check # from previous provider</th></tr></thead>
          <tbody>{period.paychecks.map((row, rowIndex) => <tr key={`${row.employee_id}:${rowIndex}`}>
            <th scope="row" className="py-2 pr-3 font-medium">{row.source_employee_name}</th>
            <td className="py-2"><Input aria-label={`Check # from previous provider — ${row.source_employee_name}`} autoComplete="off" maxLength={255} value={row.provider_payment_reference ?? ""} onChange={(e) => onChange({ ...period, paychecks: period.paychecks.map((check, index) => index === rowIndex ? { ...check, provider_payment_reference: e.target.value } : check) })} /></td>
          </tr>)}</tbody>
        </table>
      </div>
      <div className="space-y-3">
        {period.paychecks.map((row, rowIndex) => (
          <PaycheckEditor
            key={`${row.employee_id}:${rowIndex}`}
            row={row}
            problems={problems[rowIndex]}
            employees={manual ? employees : undefined}
            onChange={(next) => changeCheck(rowIndex, next)}
            onRemove={manual ? () => onChange({ ...period, paychecks: period.paychecks.filter((_, i) => i !== rowIndex), register_totals: {} }) : undefined}
          />
        ))}
        {manual && employees[0] && (
          <Button variant="outline" size="sm" onClick={() => onChange({ ...period, paychecks: [...period.paychecks, emptyCheck(employees[0])], register_totals: {} })}>
            <Plus className="mr-2 h-4 w-4" aria-hidden /> Add a paycheck
          </Button>
        )}
      </div>
      <div className="rounded-xl bg-neutral-50 p-3">
        <h4 className="text-sm font-semibold">Register totals for this pay date</h4>
        <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-4">
          {REGISTER_KEYS.map((key) => (
            <div key={key} className="min-w-0">
              {enterTotals ? (
                <Input
                  label={registerLabels[key]}
                  inputMode="decimal"
                  value={period.register_totals[key] ?? ""}
                  error={differences[key] ? `Paychecks total ${money(totals[key])} (${signedMoney(differences[key]!)})` : undefined}
                  onChange={(e) => onChange({ ...period, register_totals: { ...period.register_totals, [key]: e.target.value } })}
                />
              ) : (
                <>
                  <dt className="text-xs text-neutral-600">{registerLabels[key]}</dt>
                  <dd className="tabular-nums text-sm font-semibold">{money(totals[key])}</dd>
                </>
              )}
            </div>
          ))}
        </dl>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button disabled={hasProblems || !period.source_reference.trim() || Object.keys(differences).length > 0} onClick={confirmMatch}>
            <Check className="mr-2 h-4 w-4" aria-hidden /> Matches the register
          </Button>
          {!enterTotals && (
            <Button variant="outline" onClick={() => { setEnterTotals(true); onChange({ ...period, register_totals: { ...totals } }); }}>
              Totals are different
            </Button>
          )}
          {manual && (
            <Button variant="ghost" onClick={onRemove}>
              Remove this pay date
            </Button>
          )}
        </div>
        {hasProblems && <p className="mt-2 text-sm text-danger-700">Fix the highlighted paycheck amounts first.</p>}
        {!hasProblems && Object.keys(differences).length > 0 && (
          <p className="mt-2 text-sm text-danger-700">The paychecks don’t add up to the register. Correct the paycheck that’s different.</p>
        )}
      </div>
    </div>
  );
}

function PaycheckEditor({
  row,
  problems,
  employees,
  onChange,
  onRemove,
}: {
  row: HistoryCheck;
  problems: Partial<Record<AmountKey | BreakdownKey, string>>;
  employees?: HistoryEmployee[];
  onChange: (row: HistoryCheck) => void;
  onRemove?: () => void;
}) {
  const hiddenProblem = [...WAGE_COLUMNS, ...EMPLOYER_COLUMNS, ...OTHER_COLUMNS].some((key) => problems[key]) || (Object.keys(breakdownLabels) as BreakdownKey[]).some((key) => problems[key]);
  const [more, setMore] = useState(hiddenProblem);
  const field = (key: AmountKey, label: string = amountLabels[key]) => (
    <Input key={key} label={label} inputMode="decimal" value={row[key]} error={problems[key]} onChange={(e) => onChange(setPaycheckAmount(row, key, e.target.value))} />
  );
  return (
    <div className="space-y-3 rounded-xl border border-neutral-200 p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        {employees ? (
          <div className="min-w-[12rem]">
            <Select
              label="Employee"
              value={row.employee_id}
              onChange={(e) => {
                const employee = employees.find((item) => item.id === Number(e.target.value));
                if (employee) onChange({ ...row, employee_id: employee.id, source_employee_name: employee.name });
              }}
            >
              {employees.map((employee) => (
                <option key={employee.id} value={employee.id}>
                  {employee.name}
                </option>
              ))}
            </Select>
          </div>
        ) : (
          <h5 className="font-semibold">{row.source_employee_name}</h5>
        )}
        {onRemove && (
          <Button variant="ghost" size="sm" onClick={onRemove}>
            Remove
          </Button>
        )}
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 xl:grid-cols-7">{MAIN_COLUMNS.map((key) => field(key, SHORT[key]))}</div>
      <button type="button" aria-expanded={more} className="flex min-h-11 items-center gap-1 text-sm font-semibold text-primary-800 sm:min-h-0" onClick={() => setMore(!more)}>
        {more ? <ChevronDown className="h-4 w-4" aria-hidden /> : <ChevronRight className="h-4 w-4" aria-hidden />}
        Taxable wages, employer taxes and details
        {hiddenProblem && !more && <AlertTriangle className="h-4 w-4 text-danger-600" aria-label="Has a problem" />}
      </button>
      {more && (
        <div className="space-y-4">
          <div>
            <h6 className="mb-2 text-xs font-semibold uppercase tracking-wide text-neutral-500">Taxable wages (from the register)</h6>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">{WAGE_COLUMNS.map((key) => field(key))}</div>
          </div>
          <div>
            <h6 className="mb-2 text-xs font-semibold uppercase tracking-wide text-neutral-500">Employer</h6>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">{EMPLOYER_COLUMNS.map((key) => field(key))}</div>
          </div>
          <div>
            <h6 className="mb-2 text-xs font-semibold uppercase tracking-wide text-neutral-500">Other amounts</h6>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">{OTHER_COLUMNS.map((key) => field(key))}</div>
          </div>
          {(Object.keys(breakdownLabels) as BreakdownKey[]).map((key) => (
            <BreakdownEditor key={key} field={key} row={row} problem={problems[key]} onChange={onChange} />
          ))}
        </div>
      )}
    </div>
  );
}

function BreakdownEditor({ field, row, problem, onChange }: { field: BreakdownKey; row: HistoryCheck; problem?: string; onChange: (row: HistoryCheck) => void }) {
  const lines = row[field] || [];
  return (
    <div className="space-y-2">
      <h6 className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{breakdownLabels[field]} lines</h6>
      {lines.map((line, index) => (
        <div key={index} className="grid grid-cols-[minmax(0,1fr)_7rem_auto] items-end gap-2">
          <Input label="Label" value={line.label} onChange={(e) => onChange({ ...row, [field]: lines.map((old, i) => (i === index ? { ...old, label: e.target.value } : old)) })} />
          <Input label="Amount" inputMode="decimal" value={line.amount} onChange={(e) => onChange({ ...row, [field]: lines.map((old, i) => (i === index ? { ...old, amount: e.target.value } : old)) })} />
          <Button aria-label={`Remove ${breakdownLabels[field].toLowerCase()} line ${index + 1}`} variant="ghost" size="sm" onClick={() => onChange({ ...row, [field]: lines.filter((_, i) => i !== index) })}>
            <Trash2 className="h-4 w-4" aria-hidden />
          </Button>
        </div>
      ))}
      {problem && <p className="text-sm text-danger-600">{problem}</p>}
      <Button variant="ghost" size="sm" onClick={() => onChange({ ...row, [field]: [...lines, { label: "", amount: "0.00" }] })}>
        <Plus className="mr-1 h-4 w-4" aria-hidden /> Add a line
      </Button>
    </div>
  );
}

function RecordStep({
  payload,
  files,
  preview,
  remaining,
  onFiles,
  onChange,
  onGoTo,
  onCheck,
  onRecord,
}: {
  payload: HistoryPayload;
  files: File[];
  preview: HistoryPreview | null;
  remaining: ReturnType<typeof remainingWork>;
  onFiles: (files: File[]) => void;
  onChange: (next: HistoryPayload) => void;
  onGoTo: (step: number) => void;
  onCheck: () => void;
  onRecord: () => void;
}) {
  const quarter = takeoverQuarter(payload.takeover_on);
  const earlier = quarter > 1 ? `Q1${quarter > 2 ? `–Q${quarter - 1}` : ""}` : "";
  return (
    <>
      <PaymentReferences rows={payload.periods.flatMap((period) => period.paychecks.map((check) => ({ pay_date: period.pay_date, name: check.source_employee_name, reference: check.provider_payment_reference })))} />
      <Input
        label="Attach the provider’s paid registers (up to 10 files, 10 MB each)"
        type="file"
        multiple
        accept=".pdf,.csv,.xlsx,.xls,.txt,.json,.png,.jpg,.jpeg"
        helperText={files.length ? `${files.length} file(s) attached: ${files.map((file) => file.name).join(", ")}` : "Files are attached when you record, so reattach them if you reload the page."}
        onChange={(e) => onFiles(Array.from(e.target.files || []))}
      />
      <label className="flex items-start gap-3 text-sm leading-6">
        <input type="checkbox" className="mt-1.5 h-4 w-4 shrink-0" checked={payload.complete_history_confirmed} onChange={(e) => onChange({ ...payload, complete_history_confirmed: e.target.checked })} />
        I checked every pay date and paycheck against the previous provider’s paid registers, including taxable wages, and this is everyone they paid in {payload.tax_year}.
      </label>
      <label className="flex items-start gap-3 text-sm leading-6">
        <input type="checkbox" className="mt-1.5 h-4 w-4 shrink-0" checked={payload.same_employer_confirmed} onChange={(e) => onChange({ ...payload, same_employer_confirmed: e.target.checked })} />
        The employer and EIN didn’t change.{earlier ? ` The previous provider filed ${earlier}.` : ""} Cornerstone files Q{quarter} and the year-end W-2GU/W-3SS.
      </label>
      {remaining.length > 0 ? (
        <div className="rounded-xl border border-warning-200 bg-warning-50 p-3 text-sm text-warning-900">
          <p className="font-semibold">Before you can record</p>
          <ul className="mt-1 list-disc space-y-1 pl-5">
            {remaining.map((item) => (
              <li key={item.text}>
                <button type="button" className="text-left underline" onClick={() => onGoTo(item.step)}>
                  {item.text}
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : preview?.ready ? (
        <p className="flex items-center gap-2 rounded-xl border border-success-200 bg-success-50 p-3 text-sm font-semibold text-success-800">
          <CheckCircle2 className="h-5 w-5" aria-hidden /> Everything checks out: {payload.periods.length} pay dates, {money(preview.totals?.gross_pay)} gross.
        </p>
      ) : (
        preview && (
          <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">
            <p className="font-semibold">Fix this before recording</p>
            <ul className="mt-1 list-disc space-y-1 pl-5">
              {preview.errors.map((message) => (
                <li key={message}>{message}</li>
              ))}
            </ul>
          </div>
        )
      )}
      <div className="flex flex-wrap gap-3">
        <Button variant={preview?.ready ? "outline" : "primary"} disabled={remaining.length > 0} onClick={onCheck}>
          Check everything
        </Button>
        <Button disabled={!preview?.ready || remaining.length > 0} onClick={onRecord}>
          Record history…
        </Button>
      </div>
    </>
  );
}

function EmployeeTotalsTable({ rows, caption }: { rows: EmployeeTotals[]; caption: string }) {
  return (
    <div className="overflow-x-auto rounded-xl border border-neutral-200">
      <table className="w-full text-left text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead className="bg-neutral-50 text-xs text-neutral-600">
          <tr>
            {["Employee", "Gross", "Income tax", "SS wages", "Medicare wages", "Net"].map((label) => (
              <th key={label} scope="col" className="whitespace-nowrap px-3 py-2 font-semibold">
                {label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-neutral-100">
          {rows.map((row) => (
            <tr key={row.employee_id}>
              <th scope="row" className="whitespace-nowrap px-3 py-2 font-medium">{row.name}</th>
              {[row.gross, row.tax, row.ss, row.medicare, row.net].map((value, index) => (
                <td key={index} className="whitespace-nowrap px-3 py-2 tabular-nums">{money(value)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ConfirmCheckbox({ checked, onChange, children }: { checked: boolean; onChange: (checked: boolean) => void; children: ReactNode }) {
  return (
    <label className="flex items-start gap-3 text-sm leading-6">
      <input type="checkbox" className="mt-1.5 h-4 w-4 shrink-0" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>{children}</span>
    </label>
  );
}

function RecordDialog({ open, payload, employees, files, busy, onClose, onConfirm }: { open: boolean; payload: HistoryPayload; employees: HistoryEmployee[]; files: File[]; busy: boolean; onClose: () => void; onConfirm: () => void }) {
  const [checked, setChecked] = useState(false);
  const rows = useMemo(() => employeeTotals(payload, employees), [payload, employees]);
  useResetOnClose(open, () => setChecked(false));
  const checks = payload.periods.reduce((sum, period) => sum + period.paychecks.length, 0);
  const gross = rows.reduce((sum, row) => sum.plus(row.gross), decimal("0"));
  const net = rows.reduce((sum, row) => sum.plus(row.net), decimal("0"));
  const dates = payload.periods.map((period) => period.pay_date).sort();
  return (
    <Dialog open={open} onOpenChange={(next) => { if (!busy) { setChecked(false); if (!next) onClose(); } }}>
      <DialogContent className="dialog-wide w-full max-w-2xl sm:!mx-auto">
        <DialogHeader>
          <DialogTitle>Record {payload.provider_name || "previous provider"} history?</DialogTitle>
          <DialogDescription>
            {payload.periods.length} pay dates ({shortDate(dates[0])} – {shortDate(dates.at(-1))}) · {checks} paychecks · {money(gross)} gross · {money(net)} net · {files.length} register file(s)
          </DialogDescription>
        </DialogHeader>
        <EmployeeTotalsTable rows={rows} caption="Year-to-date amounts this history will add" />
        <PaymentReferences rows={payload.periods.flatMap((period) => period.paychecks.map((check) => ({ pay_date: period.pay_date, name: check.source_employee_name, reference: check.provider_payment_reference })))} />
        <ul className="list-disc space-y-1 pl-5 text-sm leading-6 text-neutral-700">
          <li>Saves these pay dates as payroll the previous provider already paid, with your register files.</li>
          <li>The original runs stay for reference and can’t be paid again. No checks, payments, deposits or emails are created.</li>
          <li>Year-to-date totals change only after you turn them on in the next step.</li>
        </ul>
        <ConfirmCheckbox checked={checked} onChange={setChecked}>
          I checked these amounts against the provider’s paid registers.
        </ConfirmCheckbox>
        <DialogFooter>
          <Button variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button disabled={!checked} loading={busy} onClick={onConfirm}>Record history</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function balancesFor(record: HistoryOnboarding, employees: HistoryEmployee[]): EmployeeTotals[] {
  return (record.employee_totals ?? []).map((row) => ({
    employee_id: row.employee_id,
    name: employees.find((employee) => employee.id === row.employee_id)?.name ?? `Employee ${row.employee_id}`,
    gross: decimal(row.gross_pay),
    tax: decimal(row.federal_income_tax),
    ss: decimal(row.social_security_taxable_wages).plus(decimal(row.social_security_taxable_tips)),
    medicare: decimal(row.medicare_taxable_wages),
    net: decimal(row.net_pay),
    checks: row.paycheck_count,
  }));
}

/** Clears a dialog's confirmation whenever it closes, however it was closed. */
function useResetOnClose(open: boolean, reset: () => void) {
  useEffect(() => {
    if (!open) reset();
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
}

function ActivateDialog({ open, record, employees, busy, onClose, onConfirm }: { open: boolean; record: HistoryOnboarding; employees: HistoryEmployee[]; busy: boolean; onClose: () => void; onConfirm: () => void }) {
  const [checked, setChecked] = useState(false);
  const quarter = takeoverQuarter(record.takeover_on);
  const rows = useMemo(() => balancesFor(record, employees), [record, employees]);
  useResetOnClose(open, () => setChecked(false));
  return (
    <Dialog open={open} onOpenChange={(next) => { if (!busy) { setChecked(false); if (!next) onClose(); } }}>
      <DialogContent className="dialog-wide w-full max-w-2xl sm:!mx-auto">
        <DialogHeader>
          <DialogTitle>Turn on year-to-date totals?</DialogTitle>
          <DialogDescription>
            Adds {record.periods.length} pay dates · {money(record.totals.gross_pay)} gross · {money(record.totals.net_pay)} net to each employee’s {record.tax_year} year-to-date.
          </DialogDescription>
        </DialogHeader>
        <EmployeeTotalsTable rows={rows} caption="Year-to-date amounts being turned on" />
        <ul className="list-disc space-y-1 pl-5 text-sm leading-6 text-neutral-700">
          <li>New Cornerstone payroll will continue Social Security and Medicare from these totals.</li>
          <li>{quarter > 1 ? `Q1${quarter > 2 ? `–Q${quarter - 1}` : ""} stay with the previous provider’s filings. ` : ""}Cornerstone owns Q{quarter} and the year-end W-2GU/W-3SS, including this history once.</li>
          <li>You can still undo this until the first live payroll is committed.</li>
        </ul>
        <ConfirmCheckbox checked={checked} onChange={setChecked}>
          I reviewed the recorded pay dates and register files.
        </ConfirmCheckbox>
        <DialogFooter>
          <Button variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button disabled={!checked} loading={busy} onClick={onConfirm}>Turn on year-to-date</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ReverseDialog({ open, busy, onClose, onConfirm }: { open: boolean; busy: boolean; onClose: () => void; onConfirm: (reason: string) => void }) {
  const [checked, setChecked] = useState(false);
  const [reason, setReason] = useState("");
  useResetOnClose(open, () => { setChecked(false); setReason(""); });
  return (
    <Dialog open={open} onOpenChange={(next) => { if (!busy) { setChecked(false); if (!next) onClose(); } }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Undo this history?</DialogTitle>
          <DialogDescription>
            Removes it from year-to-date totals and filings and brings back the original pay dates. Files and the audit trail are kept. First delete any Cornerstone payroll you started after it.
          </DialogDescription>
        </DialogHeader>
        <Input label="Reason" value={reason} onChange={(e) => setReason(e.target.value)} />
        <ConfirmCheckbox checked={checked} onChange={setChecked}>
          I understand the original pay dates stay marked as already paid and must be recorded again before live payroll.
        </ConfirmCheckbox>
        <DialogFooter>
          <Button variant="outline" disabled={busy} onClick={onClose}>Keep history</Button>
          <Button variant="danger" disabled={!checked || !reason.trim()} loading={busy} onClick={() => onConfirm(reason)}>Undo history</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function SavedHistory({
  record,
  employees,
  companyId,
  canManage,
  busy,
  onDownload,
  onActivate,
  onReverse,
  readinessGaps,
}: {
  record: HistoryOnboarding;
  employees: HistoryEmployee[];
  companyId: number | null;
  canManage: boolean;
  busy: boolean;
  onDownload: (record: HistoryOnboarding, file: HistoryOnboarding["source_files"][number]) => void;
  onActivate: () => void;
  onReverse: () => void;
  readinessGaps: NonNullable<HistoryPage["readiness_gaps"]>;
}) {
  const checks = record.periods.reduce((sum, period) => sum + period.paycheck_count, 0);
  const quarter = takeoverQuarter(record.takeover_on);
  const isActive = record.status === "active";
  return (
    <section className="space-y-5 rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6" aria-label="Recorded history">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-lg font-semibold">
          {record.provider_name} · {record.tax_year}
        </h2>
        <Badge variant={isActive ? "success" : "warning"}>{isActive ? "Year-to-date on" : "Recorded · year-to-date not on yet"}</Badge>
      </div>
      <p className="text-sm leading-6">
        {record.periods.length} pay dates · {checks} paychecks · {money(record.totals.gross_pay)} gross · {money(record.totals.net_pay)} net · Cornerstone takes over {shortDate(record.takeover_on)}
      </p>
      {!isActive && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-primary-200 bg-primary-50 p-4">
          <p className="text-sm text-primary-900">Next: check the pay dates below, then turn on year-to-date totals so new payroll continues from them.</p>
          <Button disabled={!canManage || busy} onClick={onActivate}>Turn on year-to-date…</Button>
        </div>
      )}
      {isActive && (
        <div className="space-y-2 rounded-xl border border-success-200 bg-success-50 p-4 text-sm text-success-900">
          <p className="flex items-center gap-2 font-semibold"><CheckCircle2 className="h-5 w-5" aria-hidden /> Included in year-to-date and filings</p>
          <p>{quarter > 1 ? `Q1${quarter > 2 ? `–Q${quarter - 1}` : ""}: previous provider’s filings (for reference). ` : ""}Q{quarter} and year-end W-2GU/W-3SS: Cornerstone, including this history.</p>
          <LivePayrollNextSteps record={record} companyId={companyId} readinessGaps={readinessGaps} />
        </div>
      )}
      {(record.employee_totals ?? []).length > 0 && (
        <div className="space-y-2">
          <h3 className="font-semibold">{isActive ? "Year-to-date by employee" : "Year-to-date this history adds"}</h3>
          <EmployeeTotalsTable rows={balancesFor(record, employees)} caption="Year-to-date by employee" />
        </div>
      )}
      <div className="space-y-2">
        <h3 className="font-semibold">Pay dates</h3>
        <div className="overflow-x-auto rounded-xl border border-neutral-200">
          <table className="w-full text-left text-sm">
            <caption className="sr-only">Recorded pay dates</caption>
            <thead className="bg-neutral-50 text-xs text-neutral-600">
              <tr>
                {["Paid", "Period", "Paychecks", "Gross", "Net"].map((label) => (
                  <th key={label} scope="col" className="whitespace-nowrap px-3 py-2 font-semibold">{label}</th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-100">
              {record.periods.map((period) => (
                <tr key={period.id}>
                  <td className="whitespace-nowrap px-3 py-2">{shortDate(period.pay_date)}</td>
                  <td className="whitespace-nowrap px-3 py-2">{periodLabel(period)}</td>
                  <td className="px-3 py-2">{period.paycheck_count}</td>
                  <td className="whitespace-nowrap px-3 py-2 tabular-nums">{money(period.totals.gross_pay)}</td>
                  <td className="whitespace-nowrap px-3 py-2 tabular-nums">{money(period.totals.net_pay)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
      <PaymentReferences rows={(record.payment_references ?? []).map((row) => ({ ...row, name: employees.find((employee) => employee.id === row.employee_id)?.name ?? `Employee ${row.employee_id}` }))} />
      <div className="space-y-2">
        <h3 className="font-semibold">Register files</h3>
        {record.source_files.map((file) => (
          <div key={file.id} className="flex min-w-0 flex-wrap items-center gap-2 text-sm">
            <Button size="sm" variant="outline" disabled={busy} onClick={() => onDownload(record, file)}>
              <FileDown className="mr-2 h-4 w-4" aria-hidden /> Download
            </Button>
            <span className="min-w-0 break-all">{file.original_filename}</span>
            {file.verification_status !== "verified" && <Badge variant="warning">{file.verification_status}</Badge>}
          </div>
        ))}
      </div>
      {record.can_reverse && canManage && (
        <div className="border-t border-neutral-100 pt-4">
          <Button variant="ghost" disabled={busy} onClick={onReverse}>
            Undo this history…
          </Button>
        </div>
      )}
    </section>
  );
}

function PaymentReferences({ rows }: { rows: Array<{ pay_date: string; name: string; reference?: string | null }> }) {
  if (!rows.length) return null;
  return <div className="space-y-2">
    <h3 className="font-semibold">Checks from the previous provider</h3>
    <div className="max-h-64 overflow-auto rounded-xl border border-neutral-200">
      <table className="w-full text-left text-sm">
        <thead className="bg-neutral-50"><tr>{["Paid", "Employee", "Check # from previous provider"].map((label) => <th key={label} scope="col" className="px-3 py-2 font-semibold">{label}</th>)}</tr></thead>
        <tbody>{rows.map((row, index) => <tr key={index} className="border-t border-neutral-100"><td className="whitespace-nowrap px-3 py-2">{shortDate(row.pay_date)}</td><td className="px-3 py-2">{row.name}</td><td className="max-w-48 break-all px-3 py-2 font-mono">{row.reference || "Not recorded"}</td></tr>)}</tbody>
      </table>
    </div>
  </div>;
}

function LivePayrollNextSteps({ record, companyId, readinessGaps }: { record: HistoryOnboarding; companyId: number | null; readinessGaps: NonNullable<HistoryPage["readiness_gaps"]> }) {
  const numericReferences = (record.payment_references ?? []).map((row) => row.reference?.trim() ?? "").filter((value) => /^\d+$/.test(value)).map(Number).filter((value) => Number.isSafeInteger(value) && value >= 0 && value < 2_147_483_647);
  const nextNumber = numericReferences.length ? Math.max(...numericReferences) + 1 : undefined;
  const lastEnd = record.periods.map((period) => period.end_date).sort().at(-1);
  const lastPayDate = record.periods.map((period) => period.pay_date).sort().at(-1);
  const lastBoundary = [lastEnd, lastPayDate].filter(Boolean).sort().at(-1);
  return <div className="space-y-3 border-t border-success-200 pt-3">
    <h3 className="font-semibold">Before the first live payroll</h3>
    <p>Confirm these settings before paying employees through Cornerstone.</p>
    {record.can_reverse && <>
      <Link to={`/check-settings?company_id=${companyId}${nextNumber ? `&suggested_next=${nextNumber}` : ""}#next-check-number`} className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline">Set the next live check number{nextNumber ? ` (suggested: ${nextNumber})` : ""}</Link>
      <p>Use the next number on the client’s actual check stock. You can edit the suggestion before saving.</p>
      <Link to={`/companies/${companyId}/pay-runs${lastBoundary ? `?new_after=${lastBoundary}` : ""}`} className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline">Create the first live pay period</Link>
      <p>Start after the last historical period and pay date. Confirm the period end and first unpaid pay date with the client.</p>
    </>}
    {readinessGaps.length > 0 ? <div className="rounded-lg border border-warning-200 bg-warning-50 p-3 text-warning-950">
      <p className="font-semibold">Employee documents to resolve before approval ({readinessGaps.length})</p>
      <ul className="mt-2 space-y-2">{readinessGaps.map((gap, index) => <li key={index}><Link className="inline-block min-h-11 py-2 underline" to={`/companies/${companyId}/employees/${gap.employee_id}/edit?return_to=${encodeURIComponent(`/companies/${companyId}/prior-provider-history`)}#employee-documents`}>{gap.employee_name}: {gap.label} ({gap.status.replaceAll("_", " ")})</Link></li>)}</ul>
    </div> : <p>Required employee documents have no outstanding checklist gaps. Normal payroll setup and approval checks still apply.</p>}
    <Link to={`/companies/${companyId}/pay-runs`} className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline">Go to pay runs</Link>
  </div>;
}
