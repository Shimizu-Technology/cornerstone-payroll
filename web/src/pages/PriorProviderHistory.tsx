import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router";
import Decimal from "decimal.js";
import { Archive, CheckCircle2, FileDown, Plus, ShieldCheck } from "lucide-react";
import { Header } from "@/components/layout/Header";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { useCompany } from "@/contexts/CompanyContext";
import { useAuth } from "@/contexts/AuthContext";
import {
  priorProviderHistoryApi,
  amountLabels,
  registerLabels,
  breakdownLabels,
  type AmountKey,
  type BreakdownKey,
  type HistoryCheck,
  type HistoryPage,
  type HistoryPayload,
  type HistoryPeriod,
  type HistoryPreview,
  type HistoryOnboarding,
} from "@/services/priorProviderHistory";

const money = (value?: string) =>
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value || 0));
const blankPayload = (): HistoryPayload => ({
  tax_year: new Date().getFullYear(),
  takeover_on: `${new Date().getFullYear()}-11-01`,
  provider_name: "",
  periods: [],
  identities: {},
  complete_history_confirmed: false,
  same_employer_confirmed: false,
});
function checkTotals(period: HistoryPeriod): Record<string, string> {
  const decimal = (value: string) => {
    try {
      return new Decimal(value || 0);
    } catch {
      return new Decimal(0);
    }
  };
  const sum = (fields: AmountKey[]) =>
    period.paychecks
      .reduce((total, row) => fields.reduce((v, field) => v.plus(decimal(row[field])), total), new Decimal(0))
      .toFixed(2);
  return {
    ...Object.fromEntries(
      (Object.keys(registerLabels) as Array<keyof typeof registerLabels>)
        .filter((k) => k !== "deductions" && k !== "employer_taxes")
        .map((key) => [key, sum([key as AmountKey])])
    ),
    deductions: sum(["pretax_deductions", "after_tax_deductions"]),
    employer_taxes: sum(["employer_social_security_tax", "employer_medicare_tax"]),
  };
}
function emptyCheck(employee: { id: number; name: string }): HistoryCheck {
  return {
    ...(Object.fromEntries(Object.keys(amountLabels).map((key) => [key, "0.00"])) as Record<AmountKey, string>),
    employee_id: employee.id,
    source_employee_name: employee.name,
    earnings_breakdown: [],
    pretax_deduction_breakdown: [],
    after_tax_deduction_breakdown: [],
    employer_contribution_breakdown: [],
  } as HistoryCheck;
}
function AmountInput({
  label,
  value,
  disabled,
  onChange,
}: {
  label: string;
  value: string;
  disabled?: boolean;
  onChange: (value: string) => void;
}) {
  return (
    <Input
      label={label}
      inputMode="decimal"
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

export function PriorProviderHistory() {
  const { activeCompanyId } = useCompany();
  const { user } = useAuth();
  return <HistoryWorkspace key={`${user?.id}:${activeCompanyId}`} companyId={activeCompanyId} />;
}

function HistoryWorkspace({ companyId }: { companyId: number | null }) {
  const { user } = useAuth();
  const draftKey = `prior-provider-history:${user?.id}:${companyId}`;
  const [page, setPage] = useState<HistoryPage | null>(null);
  const [payload, setPayload] = useState<HistoryPayload>(() => {
    try {
      const saved = sessionStorage.getItem(draftKey);
      return saved ? (JSON.parse(saved) as HistoryPayload) : blankPayload();
    } catch {
      return blankPayload();
    }
  });
  const [step, setStep] = useState(0);
  const [preview, setPreview] = useState<HistoryPreview | null>(null);
  const [files, setFiles] = useState<File[]>([]);
  const [ack, setAck] = useState("");
  const [reason, setReason] = useState("");
  const [reverseId, setReverseId] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const mounted = useRef(true);
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
      if (mounted.current && result.company_id === companyId) setPage(result);
    } catch (err) {
      if (mounted.current) setError(err instanceof Error ? err.message : "Could not load history. Retry.");
    }
  }, [companyId]);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    sessionStorage.setItem(draftKey, JSON.stringify(payload));
  }, [draftKey, payload]);
  const update = (next: HistoryPayload) => {
    setPayload(next);
    setPreview(null);
    setError("");
    if (step === 2) setStep(1);
  };
  const updatePeriod = (index: number, period: HistoryPeriod) =>
    update({ ...payload, periods: payload.periods.map((old, i) => (i === index ? period : old)) });
  const canManage = page?.can_manage === true && page.enabled;
  const active = page?.onboardings.find((record) => record.status !== "reversed");
  const perform = async (operation: () => Promise<void>) => {
    if (requestBusy.current) return;
    requestBusy.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await operation();
    } catch (err) {
      if (mounted.current) setError(err instanceof Error ? err.message : "This action could not be saved. Retry.");
    } finally {
      requestBusy.current = false;
      if (mounted.current) setBusy(false);
    }
  };
  const addManual = () =>
    update({
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
          paychecks: page?.employees[0] ? [emptyCheck(page.employees[0])] : [],
        },
      ],
    });
  const download = async (record: HistoryOnboarding, file: HistoryOnboarding["source_files"][number]) => {
    await perform(async () => {
      const blob = await priorProviderHistoryApi.sourceFile(record.id, file.id);
      if (!mounted.current) return;
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = file.original_filename;
      link.click();
      URL.revokeObjectURL(url);
    });
  };
  return (
    <>
      <Header
        title="Prior-provider history"
        subtitle="Record payroll already paid before Cornerstone took over. Reconcile the provider’s registers, then activate opening YTD."
        mobileSticky={false}
        actions={
          <Link className="text-sm font-semibold text-primary-700 underline" to="/settings/clients">
            Back to clients
          </Link>
        }
      />
      <main className="mx-auto w-full max-w-6xl space-y-6 p-4 sm:p-6 lg:p-8">
        {error && (
          <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">
            {error}
            <Button variant="ghost" size="sm" onClick={() => void load()}>
              Reload saved history
            </Button>
          </div>
        )}
        {notice && (
          <p role="status" className="rounded-xl border border-success-200 bg-success-50 p-4 text-sm text-success-800">
            {notice}
          </p>
        )}
        {!page ? (
          <p role="status">Loading history…</p>
        ) : (
          <>
            {!page.enabled && (
              <p className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm">
                Enable Historical payroll in this client’s settings before onboarding.
              </p>
            )}
            {!page.can_manage && (
              <p className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm">
                View only. An administrator or operator with Client management access must convert and activate history.
              </p>
            )}
            <div className="flex items-start gap-3 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-6 text-primary-900">
              <ShieldCheck className="mt-1 h-5 w-5 shrink-0" />
              <p>
                History preserves already-paid wages and taxes. Conversion creates no check numbers, payments, deposit
                tasks or loan repayments. Gather the paid registers, employee tax/wage summaries, Q1–Q3 returns and
                deposit receipts, plus October payment evidence.
              </p>
            </div>
            {active ? (
              <section
                className="space-y-5 rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6"
                aria-label="Saved history"
              >
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <h2 className="text-xl font-semibold">
                    {active.provider_name} · {active.tax_year}
                  </h2>
                  <span className="rounded-full bg-primary-50 px-3 py-1 text-sm font-semibold text-primary-800">
                    {active.status === "active"
                      ? "Active · included in YTD and filings"
                      : "Converted · awaiting activation"}
                  </span>
                </div>
                <p className="text-sm leading-6">
                  {active.periods.length} periods ·{" "}
                  {active.periods.reduce((sum, period) => sum + period.paycheck_count, 0)} paychecks ·{" "}
                  {money(active.totals.gross_pay)} gross · {money(active.totals.net_pay)} net. Takeover:{" "}
                  {active.takeover_on}. {active.source_run_ids.length} original runs retained as retired evidence.
                </p>
                <PeriodReview periods={active.periods} />
                {active.employee_balances.length > 0 && (
                  <div className="space-y-2">
                    <h3 className="font-semibold">Opening balances</h3>
                    {active.employee_balances.map((balance) => (
                      <p key={balance.employee_id} className="text-sm">
                        {page.employees.find((employee) => employee.id === balance.employee_id)?.name} · Gross{" "}
                        {money(balance.gross_pay)} · SS wages {money(balance.social_security_taxable_wages)} · Medicare
                        wages {money(balance.medicare_taxable_wages)}
                      </p>
                    ))}
                  </div>
                )}
                <div className="space-y-2">
                  <h3 className="font-semibold">Retained source evidence</h3>
                  {active.source_files.map((file) => (
                    <div key={file.id} className="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                      <Button size="sm" variant="outline" disabled={busy} onClick={() => void download(active, file)}>
                        <FileDown className="mr-2 h-4 w-4" />
                        Download
                      </Button>
                      <span className="min-w-0 break-all">
                        {file.original_filename} · {file.verification_status}
                      </span>
                    </div>
                  ))}
                </div>
                {active.status === "converted" && (
                  <div className="space-y-4 border-t border-neutral-200 pt-5">
                    <h3 className="font-semibold">Review and activate</h3>
                    <p className="text-sm leading-6">
                      Confirm all prior payments and wage bases are included exactly once. Activation locks the archive
                      and carries it into normal annual FICA and YTD. Quarters wholly before takeover become
                      external-provider reference history; the takeover quarter and annual W-2GU/W-3SS belong to
                      Cornerstone. Prior-provider deposits still need separate reconciliation.
                    </p>
                    <Input
                      label="Type ACTIVATE VERIFIED HISTORICAL YTD"
                      value={ack}
                      onChange={(e) => setAck(e.target.value)}
                      disabled={!canManage || busy}
                    />
                    <Button
                      disabled={!canManage || busy || ack !== "ACTIVATE VERIFIED HISTORICAL YTD"}
                      onClick={() =>
                        void perform(async () => {
                          await priorProviderHistoryApi.activate(active.id, ack);
                          if (mounted.current) {
                            setAck("");
                            setNotice(
                              "History activated. Create the first genuinely unpaid payroll after the imported dates and verify employee readiness."
                            );
                            await load();
                          }
                        })
                      }
                    >
                      Activate opening YTD and filing ownership
                    </Button>
                  </div>
                )}
                {active.status === "active" && (
                  <div className="space-y-2">
                    <h3 className="flex items-center gap-2 font-semibold">
                      <CheckCircle2 className="h-5 w-5 text-success-700" />
                      Filing ownership recorded
                    </h3>
                    <p className="text-sm">
                      {[1, 2, 3, 4]
                        .map(
                          (q) =>
                            `Q${q}: ${active.filing_responsibilities.find((row) => row.quarter === q)?.responsible_party === "external_provider" ? "external / reference" : "Cornerstone"}`
                        )
                        .join(" · ")}
                      . Annual W-2GU/W-3SS: Cornerstone, history included.
                    </p>
                    <Link
                      to={`/companies/${companyId}/pay-runs`}
                      className="inline-block py-2 text-sm font-semibold text-primary-700 underline"
                    >
                      Open live payroll
                    </Link>
                  </div>
                )}
                {active.can_reverse && canManage && (
                  <details className="border-t border-neutral-200 pt-4">
                    <summary className="cursor-pointer py-2 font-semibold">Reverse onboarding</summary>
                    <p className="my-3 text-sm leading-6">
                      Available before the first live commitment. Remove downstream uncommitted payroll first. The
                      retained history and audit trail remain, its YTD/filing inclusion is removed, and original runs
                      return to calculated status. They remain prior payments: reconcile and convert them again before
                      processing live payroll.
                    </p>
                    <Input label="Reversal reason" value={reason} onChange={(e) => setReason(e.target.value)} />
                    <Input
                      label="Type REVERSE PRIOR PROVIDER HISTORY"
                      value={reverseId === active.id ? ack : ""}
                      onChange={(e) => {
                        setReverseId(active.id);
                        setAck(e.target.value);
                      }}
                    />
                    <Button
                      className="mt-4"
                      variant="danger"
                      disabled={
                        busy || !reason.trim() || reverseId !== active.id || ack !== "REVERSE PRIOR PROVIDER HISTORY"
                      }
                      onClick={() =>
                        void perform(async () => {
                          await priorProviderHistoryApi.reverse(active.id, reason, ack);
                          if (mounted.current) {
                            setAck("");
                            setNotice(
                              "Onboarding reversed. Source runs restored; retained evidence remains available."
                            );
                            setPayload(blankPayload());
                            setStep(0);
                            await load();
                          }
                        })
                      }
                    >
                      Reverse history
                    </Button>
                  </details>
                )}
              </section>
            ) : (
              <>
                <ol aria-label="History onboarding steps" className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-5">
                  {["Select runs", "Reconcile", "Convert", "Review", "Activate"].map((label, i) => (
                    <li
                      key={label}
                      aria-current={step === i ? "step" : undefined}
                      className={`rounded-lg border px-3 py-2 ${step === i ? "border-primary-300 bg-primary-50 font-semibold text-primary-900" : "border-neutral-200 text-neutral-600"}`}
                    >
                      {i + 1}. {label}
                    </li>
                  ))}
                </ol>
                <fieldset
                  disabled={!canManage || busy}
                  className="min-w-0 space-y-5 rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6"
                >
                  <legend className="px-1 text-lg font-semibold">
                    {step === 0
                      ? "Select the prior payments"
                      : step === 1
                        ? "Reconcile to paid registers"
                        : "Confirm conversion"}
                  </legend>
                  <div className="grid gap-4 sm:grid-cols-3">
                    <Input
                      label="Previous provider"
                      value={payload.provider_name}
                      onChange={(e) => update({ ...payload, provider_name: e.target.value })}
                    />
                    <Input
                      label="Tax year"
                      type="number"
                      value={payload.tax_year}
                      onChange={(e) => update({ ...payload, tax_year: Number(e.target.value) })}
                    />
                    <Input
                      label="Cornerstone takeover date"
                      type="date"
                      value={payload.takeover_on}
                      onChange={(e) => update({ ...payload, takeover_on: e.target.value })}
                    />
                  </div>
                  {step === 0 && (
                    <>
                      <p className="text-sm text-neutral-600">
                        Only past-pay-date, calculated regular runs appear. Select every already-paid run for this year.
                        Values are a prefill for verification against the provider’s registers.
                      </p>
                      {page.candidates_overflow && (
                        <p role="alert" className="rounded-lg bg-amber-50 p-3 text-sm text-amber-900">
                          Showing {page.candidates.length} of {page.eligible_run_count} eligible runs. This workflow supports at most 60 periods for one complete year. Ask an administrator to review the source coverage before proceeding; partial history cannot be converted.
                        </p>
                      )}
                      <Button
                        variant="outline"
                        onClick={() =>
                          update({
                            ...payload,
                            periods: [
                              ...page.candidates.map((candidate) => payload.periods.find((p) => p.key === candidate.key) ?? candidate),
                              ...payload.periods.filter((p) => !p.run_id),
                            ],
                          })
                        }
                      >
                        Select all eligible runs ({page.candidates.length})
                      </Button>
                      <div className="divide-y divide-neutral-100">
                        {page.candidates.map((period) => (
                          <label key={period.key} className="flex cursor-pointer items-start gap-3 py-3 text-sm">
                            <input
                              className="mt-1 h-4 w-4"
                              type="checkbox"
                              checked={payload.periods.some((p) => p.key === period.key)}
                              onChange={(e) =>
                                update({
                                  ...payload,
                                  periods: e.target.checked
                                    ? [...payload.periods, period]
                                    : payload.periods.filter((p) => p.key !== period.key),
                                })
                              }
                            />
                            <span>
                              <strong>
                                {period.pay_date} · Run #{period.run_id}
                              </strong>
                              <span className="mt-1 block text-neutral-600">
                                {period.start_date} – {period.end_date} · {period.paychecks.length} employees ·{" "}
                                {money(period.calculated_totals?.gross_pay)} gross
                              </span>
                            </span>
                          </label>
                        ))}
                      </div>
                      {!page.candidates.length && (
                        <p className="text-sm text-neutral-600">
                          No eligible calculated runs. Add manual periods from the provider’s paid registers.
                        </p>
                      )}
                      <Button variant="outline" disabled={!page.employees.length} onClick={addManual}>
                        <Plus className="mr-2 h-4 w-4" />
                        Add manual period
                      </Button>
                      <p className="text-sm font-semibold">
                        {payload.periods.length} selected periods ·{" "}
                        {payload.periods.reduce((sum, period) => sum + period.paychecks.length, 0)} paychecks
                      </p>
                      <Button disabled={!payload.periods.length} onClick={() => setStep(1)}>
                        Continue to reconciliation
                      </Button>
                    </>
                  )}
                  {step === 1 && (
                    <>
                      <div className="space-y-4">
                        <h3 className="font-semibold">Verify existing employee identities</h3>
                        <p className="text-sm text-neutral-600">
                          Use the same legal employer. Check source names and SSN last four against the existing roster;
                          no employees will be created.
                        </p>
                        {[...new Set(payload.periods.flatMap((p) => p.paychecks.map((row) => row.employee_id)))].map(
                          (id) => (
                            <div
                              key={id}
                              className="grid gap-3 rounded-xl border border-neutral-200 p-3 sm:grid-cols-3"
                            >
                              <p className="self-center text-sm font-semibold">
                                {page.employees.find((employee) => employee.id === id)?.name}
                              </p>
                              <Input
                                label="Name on provider register"
                                autoComplete="off"
                                value={payload.identities[id]?.source_name || ""}
                                onChange={(e) =>
                                  update({
                                    ...payload,
                                    identities: {
                                      ...payload.identities,
                                      [id]: { ...payload.identities[id], source_name: e.target.value },
                                    },
                                  })
                                }
                              />
                              <Input
                                label="SSN last four from source"
                                inputMode="numeric"
                                autoComplete="off"
                                maxLength={4}
                                value={payload.identities[id]?.ssn_last4 || ""}
                                onChange={(e) =>
                                  update({
                                    ...payload,
                                    identities: {
                                      ...payload.identities,
                                      [id]: { ...payload.identities[id], ssn_last4: e.target.value },
                                    },
                                  })
                                }
                              />
                            </div>
                          )
                        )}
                      </div>
                      {payload.periods.map((period, index) => (
                        <PeriodEditor
                          key={period.key}
                          period={period}
                          index={index}
                          employees={page.employees}
                          onChange={(next) => updatePeriod(index, next)}
                          onRemove={() =>
                            update({ ...payload, periods: payload.periods.filter((_, i) => i !== index) })
                          }
                        />
                      ))}
                      <Button variant="outline" onClick={addManual}>
                        <Plus className="mr-2 h-4 w-4" />
                        Add manual period
                      </Button>
                      <Input
                        label="Attach previous provider’s paid registers (up to 10 files, 10 MB each)"
                        type="file"
                        multiple
                        accept=".pdf,.csv,.xlsx,.xls,.txt,.json,.png,.jpg,.jpeg"
                        onChange={(e) => {
                          setFiles(Array.from(e.target.files || []));
                          setPreview(null);
                        }}
                      />
                      <label className="flex items-start gap-3 text-sm leading-6">
                        <input
                          type="checkbox"
                          className="mt-1.5 h-4 w-4 shrink-0"
                          checked={payload.complete_history_confirmed}
                          onChange={(e) => update({ ...payload, complete_history_confirmed: e.target.checked })}
                        />
                        I verified complete history for all employees and prior payments in this year through the last
                        source pay date, including exact earnings, taxes, deductions, employer contributions and taxable
                        wage bases. These payments were already made by the provider.
                      </label>
                      <label className="flex items-start gap-3 text-sm leading-6">
                        <input
                          type="checkbox"
                          className="mt-1.5 h-4 w-4 shrink-0"
                          checked={payload.same_employer_confirmed}
                          onChange={(e) => update({ ...payload, same_employer_confirmed: e.target.checked })}
                        />
                        The legal employer and EIN are unchanged. I verified Q1–Q3 returns/deposits and October payment
                        evidence, and Cornerstone owns the takeover quarter and annual W-2GU/W-3SS.
                      </label>
                      <div className="flex flex-wrap gap-3">
                        <Button variant="outline" onClick={() => setStep(0)}>
                          Back to selection
                        </Button>
                        <Button
                          onClick={() =>
                            void perform(async () => {
                              const result = await priorProviderHistoryApi.preview(payload);
                              if (!mounted.current) return;
                              setPreview(result);
                              if (result.ready) {
                                setStep(2);
                                setAck("");
                              } else setError(result.errors.join("; "));
                            })
                          }
                        >
                          Check reconciliation
                        </Button>
                      </div>
                    </>
                  )}
                  {step === 2 && preview?.ready && (
                    <>
                      <p className="flex items-center gap-2 font-semibold text-success-800">
                        <CheckCircle2 className="h-5 w-5" />
                        Every register reconciles
                      </p>
                      <p className="text-sm leading-6">
                        {payload.periods.length} periods · {money(preview.totals?.gross_pay)} gross ·{" "}
                        {money(preview.totals?.net_pay)} net. Conversion saves the paid history and retires selected
                        runs in one operation. Review the saved archive before activation.
                      </p>
                      <p className="text-sm">
                        {files.length} provider file(s) selected.{" "}
                        {files.length === 0 &&
                          "Choose the registers again after a page reload; files are never stored in browser drafts."}
                      </p>
                      <Input
                        label="Type RECORD ALREADY PAID HISTORY"
                        value={ack}
                        onChange={(e) => setAck(e.target.value)}
                      />
                      <div className="flex flex-wrap gap-3">
                        <Button variant="outline" onClick={() => setStep(1)}>
                          Back to reconciliation
                        </Button>
                        <Button
                          disabled={!files.length || ack !== "RECORD ALREADY PAID HISTORY"}
                          onClick={() =>
                            void perform(async () => {
                              const requestStorageKey = `${draftKey}:request:${preview.digest}`;
                              const key = sessionStorage.getItem(requestStorageKey) || crypto.randomUUID();
                              sessionStorage.setItem(requestStorageKey, key);
                              await priorProviderHistoryApi.convert(payload, preview.digest, key, files, ack);
                              if (mounted.current) {
                                sessionStorage.removeItem(draftKey);
                                sessionStorage.removeItem(requestStorageKey);
                                setAck("");
                                setNotice(
                                  "Converted. Review the dated history and retained registers, then activate opening YTD."
                                );
                                await load();
                              }
                            })
                          }
                        >
                          <Archive className="mr-2 h-4 w-4" />
                          Convert to prior-provider history
                        </Button>
                      </div>
                    </>
                  )}
                </fieldset>
              </>
            )}
            {page.onboardings
              .filter((record) => record.status === "reversed")
              .map((record) => (
                <details key={record.id} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm">
                  <summary className="cursor-pointer font-semibold">
                    Reversed history · {record.provider_name} · {record.tax_year}
                  </summary>
                  <p className="my-3">
                    {record.reversal_reason} · {record.reversed_at}
                  </p>
                  {record.source_files.map((file) => (
                    <Button
                      key={file.id}
                      variant="outline"
                      size="sm"
                      className="mb-2 mr-2"
                      onClick={() => void download(record, file)}
                    >
                      <FileDown className="mr-2 h-4 w-4" />
                      {file.original_filename}
                    </Button>
                  ))}
                </details>
              ))}
          </>
        )}
      </main>
    </>
  );
}

function PeriodReview({ periods }: { periods: HistoryOnboarding["periods"] }) {
  return (
    <div className="overflow-x-auto rounded-xl border border-neutral-200">
      <table className="w-full text-left text-sm">
        <caption className="sr-only">Included prior-provider periods</caption>
        <thead className="bg-neutral-50">
          <tr>
            {["Pay date", "Period", "Paychecks", "Gross", "Net"].map((label) => (
              <th key={label} className="whitespace-nowrap p-3 font-semibold">
                {label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-neutral-100">
          {periods.map((period) => (
            <tr key={period.id}>
              <td className="whitespace-nowrap p-3">{period.pay_date}</td>
              <td className="whitespace-nowrap p-3">
                {period.start_date} – {period.end_date}
              </td>
              <td className="p-3">{period.paycheck_count}</td>
              <td className="whitespace-nowrap p-3 tabular-nums">{money(period.totals.gross_pay)}</td>
              <td className="whitespace-nowrap p-3 tabular-nums">{money(period.totals.net_pay)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PeriodEditor({
  period,
  index,
  employees,
  onChange,
  onRemove,
}: {
  period: HistoryPeriod;
  index: number;
  employees: HistoryPage["employees"];
  onChange: (period: HistoryPeriod) => void;
  onRemove: () => void;
}) {
  const totals = checkTotals(period);
  const changeCheck = (rowIndex: number, next: HistoryCheck) =>
    onChange({
      ...period,
      paychecks: period.paychecks.map((row, i) => (i === rowIndex ? next : row)),
      register_totals: {},
    });
  return (
    <section
      className="min-w-0 space-y-4 rounded-xl border border-neutral-200 p-3 sm:p-5"
      aria-label={`Period ${index + 1}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-semibold">
          {index + 1}. {period.pay_date || "Manual period"}
          {period.run_id ? ` · Run #${period.run_id}` : " · Manual"}
        </h3>
        <Button variant="ghost" size="sm" onClick={onRemove}>
          Remove period
        </Button>
      </div>
      {!period.run_id && (
        <div className="grid gap-3 sm:grid-cols-3">
          {(["start_date", "end_date", "pay_date"] as const).map((key) => (
            <Input
              key={key}
              label={key === "start_date" ? "Period start" : key === "end_date" ? "Period end" : "Pay date"}
              type="date"
              value={period[key]}
              onChange={(e) => onChange({ ...period, [key]: e.target.value })}
            />
          ))}
        </div>
      )}
      <Input
        label="Provider register / page reference"
        value={period.source_reference}
        onChange={(e) => onChange({ ...period, source_reference: e.target.value })}
      />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {Object.entries(registerLabels).map(([field, label]) => (
          <AmountInput
            key={field}
            label={`Register: ${label}`}
            value={period.register_totals[field] ?? ""}
            onChange={(value) =>
              onChange({ ...period, register_totals: { ...period.register_totals, [field]: value } })
            }
          />
        ))}
      </div>
      <p className="text-sm leading-6 text-neutral-600">
        Paycheck totals:{" "}
        {Object.entries(registerLabels)
          .map(([field, label]) => `${label} ${money(totals[field])}`)
          .join(" · ")}
      </p>
      <Button variant="outline" size="sm" onClick={() => onChange({ ...period, register_totals: totals })}>
        Confirm displayed totals match paid register
      </Button>
      <details>
        <summary className="cursor-pointer py-2 text-sm font-semibold text-primary-800">
          Review / correct {period.paychecks.length} employee paycheck(s) and wage bases
        </summary>
        <div className="space-y-4 pt-3">
          {period.paychecks.map((row, rowIndex) => (
            <div key={`${row.employee_id}:${rowIndex}`} className="space-y-4 rounded-xl bg-neutral-50 p-3">
              <h4 className="font-semibold">{row.source_employee_name}</h4>
              <Input label="Provider payment reference (optional)" value={row.provider_payment_reference || ''} maxLength={255} onChange={event => changeCheck(rowIndex, { ...row, provider_payment_reference: event.target.value })} />
              {!period.run_id && (
                <Select
                  label="Existing employee"
                  value={row.employee_id}
                  onChange={(e) => {
                    const employee = employees.find((item) => item.id === Number(e.target.value));
                    if (employee)
                      changeCheck(rowIndex, { ...row, employee_id: employee.id, source_employee_name: employee.name });
                  }}
                >
                  {employees.map((employee) => (
                    <option key={employee.id} value={employee.id}>
                      {employee.name}
                    </option>
                  ))}
                </Select>
              )}
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                {(Object.keys(amountLabels) as AmountKey[]).map((field) => (
                  <AmountInput
                    key={field}
                    label={amountLabels[field]}
                    value={row[field]}
                    onChange={(value) => changeCheck(rowIndex, { ...row, [field]: value })}
                  />
                ))}
              </div>
              {(Object.keys(breakdownLabels) as BreakdownKey[]).map((field) => (
                <div key={field} className="space-y-2">
                  <h5 className="text-sm font-semibold">{breakdownLabels[field]} detail</h5>
                  {row[field].map((component, ci) => (
                    <div key={ci} className="grid grid-cols-[1fr_6rem_auto] items-end gap-2">
                      <Input
                        label="Component label"
                        value={component.label}
                        onChange={(e) =>
                          changeCheck(rowIndex, {
                            ...row,
                            [field]: row[field].map((old, i) => (i === ci ? { ...old, label: e.target.value } : old)),
                          })
                        }
                      />
                      <AmountInput
                        label="Amount"
                        value={component.amount}
                        onChange={(value) =>
                          changeCheck(rowIndex, {
                            ...row,
                            [field]: row[field].map((old, i) => (i === ci ? { ...old, amount: value } : old)),
                          })
                        }
                      />
                      <Button
                        aria-label={`Remove ${breakdownLabels[field]} component ${ci + 1}`}
                        variant="ghost"
                        size="sm"
                        onClick={() =>
                          changeCheck(rowIndex, { ...row, [field]: row[field].filter((_, i) => i !== ci) })
                        }
                      >
                        ×
                      </Button>
                    </div>
                  ))}
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      changeCheck(rowIndex, { ...row, [field]: [...row[field], { label: "", amount: "0.00" }] })
                    }
                  >
                    Add {breakdownLabels[field].toLowerCase()} component
                  </Button>
                </div>
              ))}
              {!period.run_id && (
                <Button
                  variant="ghost"
                  onClick={() =>
                    onChange({
                      ...period,
                      paychecks: period.paychecks.filter((_, i) => i !== rowIndex),
                      register_totals: {},
                    })
                  }
                >
                  Remove employee paycheck
                </Button>
              )}
            </div>
          ))}
          {!period.run_id && (
            <Button
              variant="outline"
              onClick={() => {
                if (employees[0])
                  onChange({
                    ...period,
                    paychecks: [...period.paychecks, emptyCheck(employees[0])],
                    register_totals: {},
                  });
              }}
            >
              Add employee paycheck
            </Button>
          )}
        </div>
      </details>
    </section>
  );
}
