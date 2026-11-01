// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PriorProviderHistory } from "./PriorProviderHistory";
import {
  amountLabels,
  priorProviderHistoryApi,
  type AmountKey,
  type HistoryCheck,
  type HistoryOnboarding,
  type HistoryPage,
} from "@/services/priorProviderHistory";

const context = vi.hoisted(() => ({ companyId: 10 }));
vi.mock("@/contexts/AuthContext", () => ({ useAuth: () => ({ user: { id: 1 } }) }));
vi.mock("@/contexts/CompanyContext", () => ({
  useCompany: () => ({
    activeCompanyId: context.companyId,
    activeCompany: { id: context.companyId, name: "Kasperbauer-shaped local fixture" },
  }),
}));
function page(canManage = true): HistoryPage {
  const row: HistoryCheck = {
    ...(Object.fromEntries(Object.keys(amountLabels).map((key) => [key, "0.00"])) as Record<AmountKey, string>),
    employee_id: 1,
    source_employee_name: "Employee One",
    earnings_breakdown: [],
    pretax_deduction_breakdown: [],
    after_tax_deduction_breakdown: [],
    employer_contribution_breakdown: [],
  };
  return {
    company_id: context.companyId,
    enabled: true,
    can_manage: canManage,
    eligible_run_count: 1,
    candidates_overflow: false,
    employees: [{ id: 1, name: "Employee One" }],
    onboardings: [],
    candidates: [
      {
        key: "run-1",
        run_id: 1,
        source_digest: "source",
        start_date: "2026-10-16",
        end_date: "2026-10-27",
        pay_date: "2026-10-28",
        paychecks: [row],
        source_reference: "",
        register_totals: {},
        calculated_totals: { gross_pay: "0" },
      },
    ],
  };
}
function onboarding(status: "converted" | "active" = "converted"): HistoryOnboarding {
  return {
    id: 1,
    status,
    provider_name: "Prior Payroll Inc.",
    tax_year: 2026,
    takeover_on: "2026-11-01",
    converted_at: "",
    activated_at: null,
    reversed_at: null,
    reversal_reason: null,
    batch_id: 1,
    periods: [
      {
        id: 1,
        pay_date: "2026-10-28",
        start_date: "2026-10-16",
        end_date: "2026-10-27",
        paycheck_count: 1,
        totals: { gross_pay: "2000", net_pay: "1647" },
      },
    ],
    totals: { gross_pay: "2000", net_pay: "1647" },
    source_run_ids: [1],
    can_reverse: true,
    employee_balances: [],
    source_files: [],
    filing_responsibilities: [],
  };
}
function open() {
  return render(
    <MemoryRouter>
      <PriorProviderHistory />
    </MemoryRouter>
  );
}
beforeEach(() => {
  sessionStorage.clear();
  context.companyId = 10;
  vi.spyOn(priorProviderHistoryApi, "get").mockResolvedValue(page());
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("Prior-provider history", () => {
  it("keeps source register entries after a mismatch and exposes manual entry with explicit wage bases", async () => {
    vi.spyOn(priorProviderHistoryApi, "preview").mockResolvedValue({
      ready: false,
      errors: ["Register gross mismatch"],
      digest: "x",
      totals: null,
    });
    open();
    await screen.findByText("Select all eligible runs (1)");
    fireEvent.click(screen.getByText("Select all eligible runs (1)"));
    fireEvent.click(screen.getByText("Continue to reconciliation"));
    fireEvent.change(screen.getByLabelText("Provider register / page reference"), {
      target: { value: "Paid register page 3" },
    });
    fireEvent.click(screen.getByText("Check reconciliation"));
    await screen.findByText(/Register gross mismatch/);
    expect((screen.getByLabelText("Provider register / page reference") as HTMLInputElement).value).toBe(
      "Paid register page 3"
    );
    fireEvent.click(screen.getByText("Review / correct 1 employee paycheck(s) and wage bases"));
    expect(screen.getByLabelText("SS taxable wages (capped)")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Gross pay"), { target: { value: "2.." } });
    expect(screen.getByLabelText("Gross pay")).toBeTruthy();
    fireEvent.click(screen.getByText("Add manual period"));
    expect(screen.getByText(/2\. Manual period/)).toBeTruthy();
  });

  it("requires the exact activation acknowledgement and shows saved activation after reload", async () => {
    const data = page();
    data.onboardings = [onboarding()];
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(data);
    vi.spyOn(priorProviderHistoryApi, "activate").mockImplementation(async () => {
      data.onboardings = [onboarding("active")];
      return { onboarding: data.onboardings[0] };
    });
    open();
    await screen.findByText("Review and activate");
    const button = screen.getByText("Activate opening YTD and filing ownership") as HTMLButtonElement;
    expect(button.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText("Type ACTIVATE VERIFIED HISTORICAL YTD"), {
      target: { value: "ACTIVATE VERIFIED HISTORICAL YTD" },
    });
    fireEvent.click(button);
    await screen.findByText("Filing ownership recorded");
    expect(priorProviderHistoryApi.activate).toHaveBeenCalledWith(1, "ACTIVATE VERIFIED HISTORICAL YTD");
    expect(screen.getByText("Active · included in YTD and filings")).toBeTruthy();
  });

  it("lets an accountant inspect the page but disables all onboarding mutations", async () => {
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(page(false));
    open();
    await screen.findByText(/View only/);
    expect((screen.getByText("Select all eligible runs (1)").closest("fieldset") as HTMLFieldSetElement).disabled).toBe(
      true
    );
  });

  it("discards another client’s draft and ignores its pending response after switching context", async () => {
    const view = open();
    await screen.findByLabelText("Previous provider");
    fireEvent.change(screen.getByLabelText("Previous provider"), { target: { value: "Client ten private draft" } });
    context.companyId = 11;
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(page());
    view.rerender(
      <MemoryRouter>
        <PriorProviderHistory />
      </MemoryRouter>
    );
    await waitFor(() => expect((screen.getByLabelText("Previous provider") as HTMLInputElement).value).toBe(""));
  });
  it("preserves reconciled edits when returning to select all", async () => {
    open();
    await screen.findByText("Select all eligible runs (1)");
    fireEvent.click(screen.getByText("Select all eligible runs (1)"));
    fireEvent.click(screen.getByText("Continue to reconciliation"));
    fireEvent.change(screen.getByLabelText("Provider register / page reference"), { target: { value: "Verified paid register page 9" } });
    fireEvent.click(screen.getByText("Back to selection"));
    fireEvent.click(screen.getByText("Select all eligible runs (1)"));
    fireEvent.click(screen.getByText("Continue to reconciliation"));
    expect((screen.getByLabelText("Provider register / page reference") as HTMLInputElement).value).toBe("Verified paid register page 9");
  });

  it("shows incomplete candidate coverage explicitly", async () => {
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue({ ...page(), eligible_run_count: 61, candidates_overflow: true });
    open();
    await screen.findByText(/Showing 1 of 61 eligible runs/);
  });

});
