import Decimal from "decimal.js";
import {
  amountLabels,
  breakdownLabels,
  registerLabels,
  type BulkConfirmFailure,
  type BulkConfirmSummary,
  type AmountKey,
  type BreakdownKey,
  type HistoryCheck,
  type HistoryEmployee,
  type HistoryPage,
  type HistoryPayload,
  type HistoryPeriod,
} from "@/services/priorProviderHistory";

export type RegisterKey = keyof typeof registerLabels;
export const REGISTER_KEYS = Object.keys(registerLabels) as RegisterKey[];
export const AMOUNT_KEYS = Object.keys(amountLabels) as AmountKey[];
const MONEY = /^\d{1,10}(\.\d{1,2})?$/;

export const money = (value?: string | number | Decimal | null) =>
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value?.toString() || 0));

export function decimal(value?: string | null): Decimal {
  try {
    return new Decimal(value || 0);
  } catch {
    return new Decimal(0);
  }
}

export function signedMoney(value: Decimal): string {
  return `${value.isNegative() ? "−" : "+"}${money(value.abs())}`;
}

export function shortDate(iso?: string): string {
  if (!iso) return "";
  const [year, month, day] = iso.split("-").map(Number);
  return new Date(year, month - 1, day).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

export function periodLabel(period: Pick<HistoryPeriod, "start_date" | "end_date">): string {
  return `${shortDate(period.start_date)} – ${shortDate(period.end_date)}`;
}

/** Sums paychecks into the register's columns. */
export function periodTotals(period: HistoryPeriod): Record<RegisterKey, string> {
  const sum = (fields: AmountKey[]) =>
    period.paychecks
      .reduce((total, row) => fields.reduce((v, field) => v.plus(decimal(row[field])), total), new Decimal(0))
      .toFixed(2);
  return {
    gross_pay: sum(["gross_pay"]),
    federal_income_tax: sum(["federal_income_tax"]),
    social_security_tax: sum(["social_security_tax"]),
    medicare_tax: sum(["medicare_tax"]),
    deductions: sum(["pretax_deductions", "after_tax_deductions"]),
    net_pay: sum(["net_pay"]),
    employer_taxes: sum(["employer_social_security_tax", "employer_medicare_tax"]),
    employer_contributions: sum(["employer_contributions"]),
  };
}

/** Register value minus paycheck total, per column, for entered register values. */
export function registerDifferences(period: HistoryPeriod): Partial<Record<RegisterKey, Decimal>> {
  const totals = periodTotals(period);
  const result: Partial<Record<RegisterKey, Decimal>> = {};
  REGISTER_KEYS.forEach((key) => {
    const entered = period.register_totals[key];
    if (entered === undefined || entered === "" || !MONEY.test(entered)) return;
    const difference = decimal(totals[key]).minus(decimal(entered));
    if (!difference.isZero()) result[key] = difference;
  });
  return result;
}

const ISO_DATE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/** Real calendar dates ordered start ≤ end ≤ pay date, as the server requires. */
export function periodDatesValid(period: Pick<HistoryPeriod, "start_date" | "end_date" | "pay_date">): boolean {
  const dates = [period.start_date, period.end_date, period.pay_date];
  const real = dates.every((iso) => {
    if (!ISO_DATE.test(iso ?? "")) return false;
    const [year, month, day] = iso.split("-").map(Number);
    const date = new Date(Date.UTC(year, month - 1, day));
    return date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
  });
  return real && period.start_date <= period.end_date && period.end_date <= period.pay_date;
}

/** True when every register total is a valid amount (blank is not zero). */
export function registerTotalValid(period: HistoryPeriod, key: RegisterKey): boolean {
  return MONEY.test(period.register_totals[key] ?? "");
}

export function periodMatched(period: HistoryPeriod): boolean {
  const totals = periodTotals(period);
  return (
    periodDatesValid(period) &&
    period.source_reference.trim() !== "" &&
    REGISTER_KEYS.every((key) => MONEY.test(period.register_totals[key] ?? "") && decimal(period.register_totals[key]).equals(decimal(totals[key]))) &&
    period.paychecks.every((row) => Object.keys(paycheckProblems(row)).length === 0)
  );
}

export type PeriodState = "matched" | "problem" | "difference" | "to_check";
export function periodState(period: HistoryPeriod): PeriodState {
  if (period.paychecks.some((row) => Object.keys(paycheckProblems(row)).length > 0)) return "problem";
  if (Object.keys(registerDifferences(period)).length > 0) return "difference";
  return periodMatched(period) ? "matched" : "to_check";
}

const BREAKDOWN_TOTAL: Record<BreakdownKey, AmountKey> = {
  earnings_breakdown: "gross_pay",
  pretax_deduction_breakdown: "pretax_deductions",
  after_tax_deduction_breakdown: "after_tax_deductions",
  employer_contribution_breakdown: "employer_contributions",
};
const BREAKDOWN_DEFAULT_LABEL: Record<BreakdownKey, string> = {
  earnings_breakdown: "Earnings",
  pretax_deduction_breakdown: "Pre-tax deductions",
  after_tax_deduction_breakdown: "Post-tax deductions",
  employer_contribution_breakdown: "Employer contributions",
};

/**
 * Mirrors the server's paycheck rules so problems appear next to the field,
 * with the exact difference, before anything is submitted.
 */
export function paycheckProblems(row: HistoryCheck): Partial<Record<AmountKey | BreakdownKey, string>> {
  const problems: Partial<Record<AmountKey | BreakdownKey, string>> = {};
  AMOUNT_KEYS.forEach((key) => {
    if (!MONEY.test(row[key] ?? "")) problems[key] = "Enter an amount like 1234.56 (enter 0 if none)";
  });
  if (Object.keys(problems).length) return problems;
  const v = (key: AmountKey) => decimal(row[key]);
  const expectedNet = v("gross_pay")
    .minus(v("federal_income_tax"))
    .minus(v("social_security_tax"))
    .minus(v("medicare_tax"))
    .minus(v("pretax_deductions"))
    .minus(v("after_tax_deductions"));
  if (!expectedNet.equals(v("net_pay"))) {
    problems.net_pay = `Gross − taxes − deductions is ${money(expectedNet)}; net differs by ${signedMoney(v("net_pay").minus(expectedNet))}`;
  }
  (["fit_taxable_wages", "social_security_taxable_wages", "social_security_taxable_tips", "medicare_taxable_wages", "non_taxable_pay", "reported_tips"] as AmountKey[]).forEach((key) => {
    if (v(key).greaterThan(v("gross_pay"))) problems[key] = `Is ${signedMoney(v(key).minus(v("gross_pay")))} more than gross pay`;
  });
  const ss = v("social_security_taxable_wages").plus(v("social_security_taxable_tips"));
  if (ss.greaterThan(v("medicare_taxable_wages")) && !problems.social_security_taxable_wages) {
    problems.social_security_taxable_wages = `Social Security wages + tips are ${signedMoney(ss.minus(v("medicare_taxable_wages")))} more than Medicare wages`;
  }
  if (v("social_security_taxable_tips").greaterThan(v("reported_tips")) && !problems.social_security_taxable_tips) {
    problems.social_security_taxable_tips = "Can’t be more than reported tips";
  }
  if (v("additional_medicare_taxable_wages").greaterThan(v("medicare_taxable_wages"))) {
    problems.additional_medicare_taxable_wages = "Can’t be more than Medicare wages";
  }
  if (v("retirement").greaterThan(v("pretax_deductions"))) problems.retirement = "Can’t be more than pre-tax deductions";
  const classified = v("roth_retirement").plus(v("insurance")).plus(v("loans")).plus(v("tips_paid_out"));
  if (classified.greaterThan(v("after_tax_deductions"))) {
    problems.after_tax_deductions = `Roth, insurance, loans and tips paid out are ${signedMoney(classified.minus(v("after_tax_deductions")))} more than post-tax deductions`;
  }
  (Object.keys(BREAKDOWN_TOTAL) as BreakdownKey[]).forEach((field) => {
    const components = row[field] || [];
    if (components.some((component) => !component.label.trim() || !MONEY.test(component.amount))) {
      problems[field] = "Each detail line needs a label and an amount";
      return;
    }
    const sum = components.reduce((total, component) => total.plus(decimal(component.amount)), new Decimal(0));
    const target = v(BREAKDOWN_TOTAL[field]);
    if (!sum.equals(target)) problems[field] = `Detail lines total ${money(sum)}; ${signedMoney(target.minus(sum))} from the amount above`;
  });
  return problems;
}

/** Edit one amount, keeping a single matching detail line in step with it. */
export function setPaycheckAmount(row: HistoryCheck, key: AmountKey, value: string): HistoryCheck {
  const next: HistoryCheck = { ...row, [key]: value };
  const field = (Object.keys(BREAKDOWN_TOTAL) as BreakdownKey[]).find((candidate) => BREAKDOWN_TOTAL[candidate] === key);
  if (field && (row[field]?.length ?? 0) <= 1 && MONEY.test(value)) {
    const label = row[field]?.[0]?.label || BREAKDOWN_DEFAULT_LABEL[field];
    next[field] = decimal(value).isZero() ? [] : [{ label, amount: decimal(value).toFixed(2) }];
  }
  return next;
}

/** Taxable wage bases are never assumed; the operator enters each one (0 if none). */
const WAGE_BASE_KEYS: readonly AmountKey[] = [
  "fit_taxable_wages",
  "social_security_taxable_wages",
  "social_security_taxable_tips",
  "medicare_taxable_wages",
  "additional_medicare_taxable_wages",
];

export function emptyCheck(employee: HistoryEmployee): HistoryCheck {
  return {
    ...(Object.fromEntries(AMOUNT_KEYS.map((key) => [key, WAGE_BASE_KEYS.includes(key) ? "" : "0.00"])) as Record<AmountKey, string>),
    employee_id: employee.id,
    source_employee_name: employee.name,
    earnings_breakdown: [],
    pretax_deduction_breakdown: [],
    after_tax_deduction_breakdown: [],
    employer_contribution_breakdown: [],
  } as HistoryCheck;
}

/** Saved runs never contain blank money; blanks come from older calculations. */
export function normalizeCandidate(period: HistoryPeriod): HistoryPeriod {
  return {
    ...period,
    paychecks: period.paychecks.map((row) => {
      const next = { ...row };
      AMOUNT_KEYS.forEach((key) => {
        if (MONEY.test(next[key] ?? "")) next[key] = decimal(next[key]).toFixed(2);
      });
      return next;
    }),
  };
}

function firstOfNextMonth(iso: string): string {
  const [year, month] = iso.split("-").map(Number);
  const next = new Date(Date.UTC(year, month, 1));
  return next.toISOString().slice(0, 10);
}

/**
 * Default takeover: the first of the month after the last paid date. History
 * and takeover must share one tax year, so a December pay date takes over on
 * December 31 (a December 31 pay date leaves no valid date; see takeoverProblem).
 */
export function defaultTakeover(lastPay: string): string {
  const next = firstOfNextMonth(lastPay);
  return next.slice(0, 4) === lastPay.slice(0, 4) ? next : `${lastPay.slice(0, 4)}-12-31`;
}

/** Why the takeover date can't work with these pay dates, or null. */
export function takeoverProblem(payload: Pick<HistoryPayload, "takeover_on" | "tax_year" | "periods">): string | null {
  const year = String(payload.tax_year);
  const lastPay = payload.periods.map((period) => period.pay_date).filter((iso) => ISO_DATE.test(iso ?? "")).sort().at(-1);
  if (lastPay?.endsWith("-12-31") && lastPay.slice(0, 4) === year) {
    return `The last pay date is December 31, so this history covers all of ${year} and there’s no takeover date left in that year. Remove the December 31 pay date, or start ${Number(year) + 1} payroll in Cornerstone without recording ${year} history.`;
  }
  if (!ISO_DATE.test(payload.takeover_on ?? "") || payload.takeover_on.slice(0, 4) !== year) return `Choose a takeover date in ${year}.`;
  if (lastPay && lastPay >= payload.takeover_on) return `Choose a takeover date after the last pay date (${shortDate(lastPay)}).`;
  return null;
}

/** Prefill: every eligible run, takeover the month after the last paid date. */
export function initialPayload(page: HistoryPage): HistoryPayload {
  if (page.draft?.payload) return page.draft.payload;
  const periods = page.candidates.map(normalizeCandidate);
  const lastPay = periods.map((period) => period.pay_date).sort().at(-1);
  const takeover = lastPay ? defaultTakeover(lastPay) : `${new Date().getFullYear()}-11-01`;
  return {
    tax_year: Number(takeover.slice(0, 4)),
    takeover_on: takeover,
    provider_name: "",
    periods,
    identities: {},
    complete_history_confirmed: false,
    same_employer_confirmed: false,
  };
}

export function employeeIds(payload: HistoryPayload): number[] {
  return [...new Set(payload.periods.flatMap((period) => period.paychecks.map((row) => row.employee_id)))];
}

export function identityConfirmed(payload: HistoryPayload, employee?: HistoryEmployee): boolean {
  if (!employee?.ssn_last_four) return false;
  const identity = payload.identities[employee.id];
  return identity?.source_name === employee.name && identity?.ssn_last4 === employee.ssn_last_four;
}

export function takeoverQuarter(takeoverOn: string): number {
  return Math.floor((Number(takeoverOn.slice(5, 7)) - 1) / 3) + 1;
}

export type EmployeeTotals = { employee_id: number; name: string; gross: Decimal; tax: Decimal; ss: Decimal; medicare: Decimal; net: Decimal; checks: number };
export function employeeTotals(payload: HistoryPayload, employees: HistoryEmployee[]): EmployeeTotals[] {
  return employeeIds(payload).map((id) => {
    const rows = payload.periods.flatMap((period) => period.paychecks.filter((row) => row.employee_id === id));
    const sum = (key: AmountKey) => rows.reduce((total, row) => total.plus(decimal(row[key])), new Decimal(0));
    return {
      employee_id: id,
      name: employees.find((employee) => employee.id === id)?.name || rows[0]?.source_employee_name || `Employee ${id}`,
      gross: sum("gross_pay"),
      tax: sum("federal_income_tax"),
      ss: sum("social_security_taxable_wages").plus(sum("social_security_taxable_tips")),
      medicare: sum("medicare_taxable_wages"),
      net: sum("net_pay"),
      checks: rows.length,
    };
  });
}

export type Remaining = { step: number; text: string };
export function remainingWork(payload: HistoryPayload, employees: HistoryEmployee[], filesAttached: boolean): Remaining[] {
  const items: Remaining[] = [];
  if (!payload.provider_name.trim()) items.push({ step: 0, text: "Enter the previous provider’s name" });
  if (!payload.periods.length) items.push({ step: 0, text: "Choose at least one pay date" });
  const takeover = takeoverProblem(payload);
  if (takeover) items.push({ step: 0, text: takeover });
  const ids = employeeIds(payload);
  const unconfirmed = ids.filter((id) => !identityConfirmed(payload, employees.find((employee) => employee.id === id))).length;
  if (unconfirmed) items.push({ step: 1, text: `Confirm ${unconfirmed} ${unconfirmed === 1 ? "employee" : "employees"} against the register` });
  const states = payload.periods.map(periodState);
  const problems = states.filter((state) => state === "problem" || state === "difference").length;
  const unchecked = states.filter((state) => state === "to_check").length;
  if (problems) items.push({ step: 2, text: `Fix ${problems} pay ${problems === 1 ? "date" : "dates"} that don’t match` });
  if (unchecked) items.push({ step: 2, text: `Check ${unchecked} of ${payload.periods.length} pay dates against the register` });
  if (!filesAttached) items.push({ step: 3, text: "Attach the provider’s paid register files" });
  if (!payload.complete_history_confirmed || !payload.same_employer_confirmed) items.push({ step: 3, text: "Tick both statements before recording" });
  return items;
}

/** Fills a blank register reference the same way as "Fill blank references". */
export function filledReference(registerName: string, payDate: string): string {
  return `${registerName.trim()} — paid ${payDate || "date"}`;
}

export function withFilledReferences(payload: HistoryPayload, registerName: string): HistoryPayload {
  if (!registerName.trim()) return payload;
  return {
    ...payload,
    periods: payload.periods.map((period) => (period.source_reference.trim() ? period : { ...period, source_reference: filledReference(registerName, period.pay_date) })),
  };
}

const FIELD_LABELS: Record<string, string> = { ...amountLabels, ...breakdownLabels };

/** Why a pay date can't be confirmed in bulk; the server applies the same rules. */
export function bulkConfirmReasons(period: HistoryPeriod, payload: Pick<HistoryPayload, "tax_year" | "takeover_on">): string[] {
  const reasons: string[] = [];
  if (!periodDatesValid(period)) reasons.push("Needs real dates in order: period start, period end, then pay date");
  else if (Number(period.pay_date.slice(0, 4)) !== payload.tax_year || period.pay_date >= payload.takeover_on) {
    reasons.push(`Pay date is not in ${payload.tax_year} before the takeover date`);
  }
  if (!period.source_reference.trim()) reasons.push("Needs a register reference (enter the register name above to fill it)");
  if (!period.paychecks.length) reasons.push("Has no paychecks");
  period.paychecks.forEach((row) => {
    Object.entries(paycheckProblems(row)).forEach(([key, message]) => {
      reasons.push(`${row.source_employee_name}: ${FIELD_LABELS[key] ?? key} — ${message}`);
    });
  });
  if (reasons.length) return reasons;
  const differences = registerDifferences(period);
  REGISTER_KEYS.forEach((key) => {
    const entered = period.register_totals[key];
    if (entered === undefined || entered === "") return;
    if (!registerTotalValid(period, key)) reasons.push(`Register ${registerLabels[key].toLowerCase()} is not a valid amount`);
    else if (differences[key]) reasons.push(`Doesn’t match the register ${registerLabels[key].toLowerCase()} (register ${money(entered)}, paychecks ${money(periodTotals(period)[key])})`);
  });
  return reasons;
}

export type BulkConfirmCheck = { failures: BulkConfirmFailure[]; summary: BulkConfirmSummary };

/** Every listed pay date must pass before all can be confirmed at once. */
export function bulkConfirmCheck(payload: HistoryPayload, registerName: string): BulkConfirmCheck {
  const filled = withFilledReferences(payload, registerName);
  const failures = filled.periods
    .map((period) => ({ key: period.key, pay_date: period.pay_date, reasons: bulkConfirmReasons(period, filled) }))
    .filter((failure) => failure.reasons.length > 0);
  const checks = filled.periods.flatMap((period) => period.paychecks);
  const sum = (key: AmountKey) => checks.reduce((total, row) => total.plus(decimal(row[key])), new Decimal(0)).toFixed(2);
  return {
    failures,
    summary: { period_count: filled.periods.length, paycheck_count: checks.length, gross_pay: sum("gross_pay"), net_pay: sum("net_pay") },
  };
}

/** The attestation shown in the dialog; the server stores the same wording. */
export function bulkConfirmStatement(summary: BulkConfirmSummary): string {
  return `I confirm these ${summary.period_count} pay dates / ${summary.paycheck_count} paychecks totaling ${money(summary.gross_pay)} gross / ${money(summary.net_pay)} net match the previous provider’s paid registers.`;
}
