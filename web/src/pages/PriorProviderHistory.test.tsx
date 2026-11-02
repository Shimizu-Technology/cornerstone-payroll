// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { StrictMode } from "react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PriorProviderHistory } from "./PriorProviderHistory";
import { ApiError } from "@/services/api";
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
  useCompany: () => ({ activeCompanyId: context.companyId, activeCompany: { id: context.companyId, name: "Kasperbauer-shaped fixture" } }),
}));

function check(employeeId: number, name: string, gross: string): HistoryCheck {
  const zero = Object.fromEntries(Object.keys(amountLabels).map((key) => [key, "0.0"])) as Record<AmountKey, string>;
  const ss = (Number(gross) * 0.062).toFixed(2);
  const medicare = (Number(gross) * 0.0145).toFixed(2);
  const tax = "100.0";
  const net = (Number(gross) - Number(ss) - Number(medicare) - 100).toFixed(2);
  return {
    ...zero,
    gross_pay: gross,
    federal_income_tax: tax,
    social_security_tax: ss,
    medicare_tax: medicare,
    employer_social_security_tax: ss,
    employer_medicare_tax: medicare,
    net_pay: net,
    fit_taxable_wages: gross,
    social_security_taxable_wages: gross,
    medicare_taxable_wages: gross,
    employee_id: employeeId,
    source_employee_name: name,
    earnings_breakdown: [{ label: "Earnings (verify source classification)", amount: gross }],
    pretax_deduction_breakdown: [],
    after_tax_deduction_breakdown: [],
    employer_contribution_breakdown: [],
  };
}

function page(canManage = true): HistoryPage {
  const candidate = (id: number, start: string, end: string) => ({
    key: `run-${id}`,
    run_id: id,
    source_digest: `digest-${id}`,
    start_date: start,
    end_date: end,
    pay_date: end,
    paychecks: [check(1, "Ana Cruz", "1500.0"), check(2, "Ben Diaz", "1400.0")],
    source_reference: "",
    register_totals: {},
    calculated_totals: { gross_pay: "2900.0" },
  });
  return {
    company_id: context.companyId,
    enabled: false,
    can_manage: canManage,
    eligible_run_count: 2,
    candidates_overflow: false,
    employees: [
      { id: 1, name: "Ana Cruz", ssn_last_four: "1111" },
      { id: 2, name: "Ben Diaz", ssn_last_four: "2222" },
    ],
    draft: null,
    onboardings: [],
    candidates: [candidate(1, "2026-09-24", "2026-10-07"), candidate(2, "2026-10-08", "2026-10-28")],
  };
}

function onboarding(status: "converted" | "active" = "converted"): HistoryOnboarding {
  return {
    id: 7,
    status,
    provider_name: "Prior Payroll Inc.",
    tax_year: 2026,
    takeover_on: "2026-11-01",
    converted_at: "",
    activated_at: null,
    reversed_at: null,
    reversal_reason: null,
    batch_id: 1,
    periods: [{ id: 1, pay_date: "2026-10-28", start_date: "2026-10-08", end_date: "2026-10-28", paycheck_count: 2, totals: { gross_pay: "2900", net_pay: "2478.15" } }],
    totals: { gross_pay: "2900", net_pay: "2478.15" },
    source_run_ids: [2],
    can_reverse: true,
    employee_balances: [],
    employee_totals: [
      { employee_id: 1, paycheck_count: 1, gross_pay: "1500", net_pay: "1285.25", federal_income_tax: "100", social_security_taxable_wages: "1500", social_security_taxable_tips: "0", medicare_taxable_wages: "1500" },
    ],
    source_files: [{ id: 3, original_filename: "register.pdf", sha256: "x", byte_size: 10, verification_status: "verified" }],
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
  vi.spyOn(priorProviderHistoryApi, "saveDraft").mockImplementation(async (payload, step, lockVersion) => ({
    draft: { payload, step, lock_version: (lockVersion ?? -1) + 1, updated_at: "2026-11-02T02:00:00Z", updated_by_name: "Mark" },
  }));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("Prior-provider history", () => {
  it("ignores a late initial load after the current load has opened an editable draft", async () => {
    let finishFirst!: (value: HistoryPage) => void;
    vi.mocked(priorProviderHistoryApi.get).mockImplementationOnce(() => new Promise(resolve => { finishFirst = resolve; })).mockResolvedValue(page());
    render(<StrictMode><MemoryRouter><PriorProviderHistory /></MemoryRouter></StrictMode>);
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.change(screen.getByLabelText("Previous payroll provider"), { target: { value: "Already entered provider" } });
    await act(async () => finishFirst(page()));
    expect((screen.getByLabelText("Previous payroll provider") as HTMLInputElement).value).toBe("Already entered provider");
  });

  it("keeps old check references visible, optional, and in the shared draft", async () => {
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.click(screen.getByRole("button", { name: /Match registers/ }));
    const input = screen.getByLabelText("Check # from previous provider — Ana Cruz");
    expect(screen.queryByLabelText("Provider check or deposit number (optional)")).toBeNull();
    fireEvent.change(input, { target: { value: "00707" } });
    fireEvent.click(screen.getByRole("button", { name: "Save progress" }));
    await waitFor(() => expect(priorProviderHistoryApi.saveDraft).toHaveBeenCalledWith(expect.objectContaining({ periods: expect.arrayContaining([expect.objectContaining({ paychecks: expect.arrayContaining([expect.objectContaining({ provider_payment_reference: "00707" })]) })]) }), 2, undefined));
  });

  it("shows saved references, check settings and document fixes after turning on YTD", async () => {
    const record = { ...onboarding("active"), payment_references: [{ employee_id: 1, pay_date: "2026-10-28", reference: "00707" }, { employee_id: 2, pay_date: "2026-10-28", reference: "DD-99999" }] };
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue({ ...page(), candidates: [], onboardings: [record], readiness_gaps: [{ employee_id: 1, employee_name: "Ana Cruz", label: "Signed withholding election", status: "missing" }] });
    open();
    await screen.findByText("00707");
    expect(screen.getByRole("link", { name: /Set the next live check number/ }).getAttribute("href")).toBe("/check-settings?company_id=10&suggested_next=708#next-check-number");
    expect(screen.getByRole("link", { name: "Create the first live pay period" }).getAttribute("href")).toBe("/companies/10/pay-runs?new_after=2026-10-28");
    expect(screen.getByRole("link", { name: /Ana Cruz: Signed withholding election/ }).getAttribute("href")).toContain("/companies/10/employees/1/edit?");
  });

  it("prefills every saved run and the takeover date, and lists what’s left", async () => {
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    expect((screen.getByLabelText("Cornerstone takes over on") as HTMLInputElement).value).toBe("2026-11-01");
    const left = screen.getByRole("complementary", { name: "What’s left" });
    expect(within(left).getByText("Enter the previous provider’s name")).toBeTruthy();
    expect(within(left).getByText("Confirm 2 employees against the register")).toBeTruthy();
    expect(within(left).getByText("Check 2 of 2 pay dates against the register")).toBeTruthy();
    fireEvent.click(within(left).getByText("Confirm 2 employees against the register"));
    fireEvent.click(screen.getAllByLabelText("Matches the register")[0]);
    expect(within(left).getByText("Confirm 1 employee against the register")).toBeTruthy();
  });

  it("shows paycheck and register differences next to the field, then marks a pay date as matching", async () => {
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.click(screen.getByRole("button", { name: /Match registers/ }));
    fireEvent.change(screen.getAllByLabelText("Gross")[0], { target: { value: "1510.00" } });
    expect(screen.getByText("Gross − taxes − deductions is $1,295.25; net differs by −$10.00")).toBeTruthy();
    fireEvent.change(screen.getAllByLabelText("Gross")[0], { target: { value: "1500.00" } });
    fireEvent.click(screen.getByRole("button", { name: "Totals are different" }));
    fireEvent.change(screen.getByLabelText("Gross pay"), { target: { value: "2950.00" } });
    expect(screen.getByText("Paychecks total $2,900.00 (−$50.00)")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Gross pay"), { target: { value: "2900.00" } });
    fireEvent.change(screen.getByLabelText("Where this is on the register"), { target: { value: "Register page 1" } });
    fireEvent.click(screen.getByRole("button", { name: "Matches the register" }));
    expect(screen.getByText("1 of 2 pay dates match")).toBeTruthy();
    expect(screen.getAllByText("Matches").length).toBe(1);
  });

  it("records through a summary dialog with a checkbox instead of a typed phrase", async () => {
    const data = page();
    data.draft = {
      payload: {
        tax_year: 2026,
        takeover_on: "2026-11-01",
        provider_name: "Prior Payroll Inc.",
        complete_history_confirmed: true,
        same_employer_confirmed: true,
        identities: { 1: { source_name: "Ana Cruz", ssn_last4: "1111" }, 2: { source_name: "Ben Diaz", ssn_last4: "2222" } },
        periods: data.candidates.map((period) => ({ ...period, source_reference: "Register", register_totals: {
          gross_pay: "2900.00", federal_income_tax: "200.00", social_security_tax: "179.80", medicare_tax: "42.05", deductions: "0.00", net_pay: "2478.15", employer_taxes: "221.85", employer_contributions: "0.00",
        } })),
      },
      step: 3,
      lock_version: 4,
      updated_at: "2026-11-02T01:00:00Z",
      updated_by_name: "Benjo",
    };
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(data);
    vi.spyOn(priorProviderHistoryApi, "preview").mockResolvedValue({ ready: true, errors: [], digest: "d", totals: { gross_pay: "5800" } });
    const convert = vi.spyOn(priorProviderHistoryApi, "convert").mockResolvedValue({ onboarding: onboarding() });
    open();
    await screen.findByText(/Saved .* by Benjo/);
    expect(screen.getByRole("heading", { name: "4. Record" })).toBeTruthy();
    fireEvent.change(screen.getByLabelText(/Attach the provider’s paid registers/), { target: { files: [new File(["x"], "register.pdf")] } });
    fireEvent.click(screen.getByRole("button", { name: "Check everything" }));
    await screen.findByText(/Everything checks out/);
    fireEvent.click(screen.getByRole("button", { name: "Record history…" }));
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByText(/2 pay dates .* 4 paychecks · \$5,800.00 gross/)).toBeTruthy();
    expect(within(dialog).getByRole("rowheader", { name: "Ana Cruz" })).toBeTruthy();
    expect(within(dialog).getAllByText("$3,000.00").length).toBe(3);
    const record = within(dialog).getByRole("button", { name: "Record history" }) as HTMLButtonElement;
    expect(record.disabled).toBe(true);
    fireEvent.click(within(dialog).getByLabelText(/I checked these amounts/));
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue({ ...page(), candidates: [], onboardings: [onboarding()] });
    fireEvent.click(record);
    await screen.findByText(/History recorded/);
    expect(convert).toHaveBeenCalledWith(expect.objectContaining({ provider_name: "Prior Payroll Inc." }), "d", expect.any(String), expect.any(Array), "RECORD ALREADY PAID HISTORY");
  });

  it("turns on year-to-date through a confirm dialog that shows each employee’s totals", async () => {
    const data = { ...page(), candidates: [], onboardings: [onboarding()] };
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(data);
    const activate = vi.spyOn(priorProviderHistoryApi, "activate").mockImplementation(async () => {
      data.onboardings = [onboarding("active")];
      return { onboarding: data.onboardings[0] };
    });
    open();
    fireEvent.click(await screen.findByRole("button", { name: "Turn on year-to-date…" }));
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByRole("rowheader", { name: "Ana Cruz" })).toBeTruthy();
    expect(within(dialog).getByText(/Cornerstone owns Q4/)).toBeTruthy();
    fireEvent.click(within(dialog).getByLabelText(/I reviewed the recorded pay dates/));
    fireEvent.click(within(dialog).getByRole("button", { name: "Turn on year-to-date" }));
    await screen.findByText("Included in year-to-date and filings");
    expect(activate).toHaveBeenCalledWith(7, "ACTIVATE VERIFIED HISTORICAL YTD");
  });

  it("saves progress and explains when someone else saved newer changes", async () => {
    vi.mocked(priorProviderHistoryApi.saveDraft).mockRejectedValueOnce(new ApiError("Benjo saved newer changes. Reload to continue from their version.", 409));
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.change(screen.getByLabelText("Previous payroll provider"), { target: { value: "ADP" } });
    fireEvent.click(screen.getByRole("button", { name: "Save progress" }));
    await screen.findByText(/Benjo saved newer changes/);
    expect(screen.getByRole("button", { name: "Load the latest version" })).toBeTruthy();
  });

  it("autosaves edits so work can be resumed", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.change(screen.getByLabelText("Previous payroll provider"), { target: { value: "ADP" } });
    await act(async () => {
      vi.advanceTimersByTime(1500);
    });
    await waitFor(() => expect(priorProviderHistoryApi.saveDraft).toHaveBeenCalledWith(expect.objectContaining({ provider_name: "ADP" }), 0, undefined));
    await screen.findByText(/^Saved/);
  });

  it("is view-only for staff who can’t record this client’s history", async () => {
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(page(false));
    open();
    await screen.findByText(/View only/);
    expect((screen.getByLabelText("Previous payroll provider").closest("fieldset") as HTMLFieldSetElement).disabled).toBe(true);
    expect(screen.queryByRole("button", { name: "Save progress" })).toBeNull();
  });

  it("drops another client’s work after switching clients", async () => {
    const view = open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.change(screen.getByLabelText("Previous payroll provider"), { target: { value: "Client ten provider" } });
    context.companyId = 11;
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue(page());
    view.rerender(
      <MemoryRouter>
        <PriorProviderHistory />
      </MemoryRouter>
    );
    await waitFor(() => expect((screen.getByLabelText("Previous payroll provider") as HTMLInputElement).value).toBe(""));
  });

  it("selects the remaining runs, not clears, when a manual pay date is also added", async () => {
    open();
    await screen.findByText(/2 pay dates · 4 paychecks/);
    fireEvent.click(screen.getAllByRole("checkbox")[1]);
    fireEvent.click(screen.getByRole("button", { name: /Add a pay date that isn’t listed/ }));
    fireEvent.click(screen.getByRole("button", { name: "Select all (2)" }));
    expect(screen.getByText(/3 pay dates · 5 paychecks/)).toBeTruthy();
    expect(screen.getByRole("button", { name: "Clear all" })).toBeTruthy();
  });

  it("shows incomplete run coverage explicitly", async () => {
    vi.mocked(priorProviderHistoryApi.get).mockResolvedValue({ ...page(), eligible_run_count: 61, candidates_overflow: true });
    open();
    await screen.findByText(/Showing 2 of 61 runs/);
  });
});
