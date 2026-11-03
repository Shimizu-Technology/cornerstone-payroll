// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { amountLabels, type AmountKey, type HistoryCheck, type HistoryPage } from "@/services/priorProviderHistory";
import { defaultTakeover, emptyCheck, initialPayload, paycheckProblems, periodMatched, periodState, remainingWork, setPaycheckAmount, takeoverProblem } from "./historyModel";

function row(overrides: Partial<Record<AmountKey, string>> = {}): HistoryCheck {
  const zero = Object.fromEntries(Object.keys(amountLabels).map((key) => [key, "0.00"])) as Record<AmountKey, string>;
  return {
    ...zero, gross_pay: "1000.00", net_pay: "900.00", federal_income_tax: "100.00", fit_taxable_wages: "1000.00",
    social_security_taxable_wages: "1000.00", medicare_taxable_wages: "1000.00", ...overrides,
    employee_id: 1, source_employee_name: "Ana Cruz",
    earnings_breakdown: [{ label: "Salary", amount: "1000.00" }], pretax_deduction_breakdown: [], after_tax_deduction_breakdown: [], employer_contribution_breakdown: [],
  };
}

describe("prior-provider history model", () => {
  it("reports the exact net difference and wage-base problems against gross", () => {
    const problems = paycheckProblems(row({ net_pay: "905.00", medicare_taxable_wages: "1200.00" }));
    expect(problems.net_pay).toBe("Gross − taxes − deductions is $900.00; net differs by +$5.00");
    expect(problems.medicare_taxable_wages).toBe("Is +$200.00 more than gross pay");
  });

  it("requires an explicit amount instead of treating a blank as zero", () => {
    expect(paycheckProblems(row({ employer_contributions: "" })).employer_contributions).toMatch(/enter 0 if none/);
  });

  it("leaves every taxable wage base blank on an added paycheck so each one is entered explicitly", () => {
    const added = emptyCheck({ id: 1, name: "Ana Cruz", ssn_last_four: "1111" });
    const bases: AmountKey[] = ["fit_taxable_wages", "social_security_taxable_wages", "social_security_taxable_tips", "medicare_taxable_wages", "additional_medicare_taxable_wages"];
    bases.forEach((key) => {
      expect(added[key]).toBe("");
      expect(paycheckProblems(added)[key]).toMatch(/enter 0 if none/);
    });
    expect(added.gross_pay).toBe("0.00");
    expect(added.net_pay).toBe("0.00");
  });

  it("keeps a single detail line in step with its total but flags split lines that no longer add up", () => {
    const edited = setPaycheckAmount(row(), "gross_pay", "1100.00");
    expect(edited.earnings_breakdown).toEqual([{ label: "Salary", amount: "1100.00" }]);
    const split = { ...row(), earnings_breakdown: [{ label: "Salary", amount: "600.00" }, { label: "Bonus", amount: "400.00" }] };
    expect(paycheckProblems(setPaycheckAmount(split, "gross_pay", "1100.00")).earnings_breakdown).toBe("Detail lines total $1,000.00; +$100.00 from the amount above");
  });

  it("prefills every run, a takeover after the last pay date and lists remaining work", () => {
    const period = { key: "run-1", run_id: 1, start_date: "2026-10-08", end_date: "2026-10-28", pay_date: "2026-10-28", source_reference: "", register_totals: {}, paychecks: [row()] };
    const payload = initialPayload({ candidates: [period], draft: null } as unknown as HistoryPage);
    expect(payload).toMatchObject({ takeover_on: "2026-11-01", tax_year: 2026 });
    expect(periodState(payload.periods[0])).toBe("to_check");
    expect(remainingWork(payload, [{ id: 1, name: "Ana Cruz", ssn_last_four: "1111" }], false).map((item) => item.step)).toEqual([0, 1, 2, 3, 3]);
  });

  it("reports a pay date as matched only with real, ordered period dates", () => {
    const totals = { gross_pay: "1000.00", federal_income_tax: "100.00", social_security_tax: "0.00", medicare_tax: "0.00", deductions: "0.00", net_pay: "900.00", employer_taxes: "0.00", employer_contributions: "0.00" };
    const period = { key: "manual-1", start_date: "2026-10-08", end_date: "2026-10-21", pay_date: "2026-10-28", source_reference: "Register p1", register_totals: totals, paychecks: [row()] };
    expect(periodMatched(period)).toBe(true);
    expect(periodState(period)).toBe("matched");
    [{ pay_date: "" }, { start_date: "" }, { end_date: "2026-02-30" }, { start_date: "2026-10-22" }, { pay_date: "2026-10-20" }].forEach((dates) => {
      expect(periodMatched({ ...period, ...dates })).toBe(false);
      expect(periodState({ ...period, ...dates })).toBe("to_check");
    });
  });

  it("keeps the default takeover inside the pay dates' tax year and explains when none is left", () => {
    expect(defaultTakeover("2026-10-28")).toBe("2026-11-01");
    expect(defaultTakeover("2026-12-15")).toBe("2026-12-31");
    const december = { key: "run-9", run_id: 9, start_date: "2026-12-01", end_date: "2026-12-14", pay_date: "2026-12-15", source_reference: "", register_totals: {}, paychecks: [row()] };
    const payload = initialPayload({ candidates: [december], draft: null } as unknown as HistoryPage);
    expect(payload).toMatchObject({ tax_year: 2026, takeover_on: "2026-12-31" });
    expect(takeoverProblem(payload)).toBeNull();
    const yearEnd = { ...december, pay_date: "2026-12-31", end_date: "2026-12-31" };
    const full = initialPayload({ candidates: [yearEnd], draft: null } as unknown as HistoryPage);
    expect(full).toMatchObject({ tax_year: 2026, takeover_on: "2026-12-31" });
    expect(takeoverProblem(full)).toMatch(/December 31.*covers all of 2026/);
    expect(remainingWork(full, [], false).map((item) => item.text)).toContain(takeoverProblem(full));
    expect(takeoverProblem({ ...payload, takeover_on: "2026-12-10" })).toMatch(/after the last pay date/);
    expect(takeoverProblem({ ...payload, takeover_on: "2027-01-01" })).toBe("Choose a takeover date in 2026.");
  });
});
