// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { amountLabels, type AmountKey, type HistoryCheck, type HistoryPage } from "@/services/priorProviderHistory";
import { initialPayload, paycheckProblems, periodState, remainingWork, setPaycheckAmount } from "./historyModel";

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
});
