import api from "./api";

export const amountLabels = {
  gross_pay: "Gross pay",
  federal_income_tax: "FIT / Guam withholding",
  social_security_tax: "Employee Social Security",
  medicare_tax: "Employee Medicare (including additional)",
  pretax_deductions: "Pre-tax deductions",
  after_tax_deductions: "Post-tax deductions",
  net_pay: "Net pay",
  employer_social_security_tax: "Employer Social Security",
  employer_medicare_tax: "Employer Medicare",
  employer_contributions: "Employer contributions",
  fit_taxable_wages: "FIT taxable wages",
  social_security_taxable_wages: "SS taxable wages (capped)",
  social_security_taxable_tips: "SS taxable tips (capped)",
  medicare_taxable_wages: "Medicare wages (uncapped)",
  additional_medicare_taxable_wages: "Additional Medicare wages",
  non_taxable_pay: "Non-taxable pay",
  reported_tips: "Reported tips",
  tips_paid_out: "Tips paid out",
  retirement: "Pre-tax retirement",
  roth_retirement: "Roth retirement",
  insurance: "Post-tax insurance",
  loans: "Loan deductions already paid",
} as const;
export type AmountKey = keyof typeof amountLabels;
export const registerLabels = {
  gross_pay: "Gross pay",
  federal_income_tax: "FIT / Guam withholding",
  social_security_tax: "Employee Social Security",
  medicare_tax: "Employee Medicare",
  deductions: "Deductions (excluding taxes)",
  net_pay: "Net pay",
  employer_taxes: "Employer SS + Medicare",
  employer_contributions: "Employer contributions",
} as const;
export type Component = { label: string; amount: string };
export const breakdownLabels = {
  earnings_breakdown: "Earnings",
  pretax_deduction_breakdown: "Pre-tax deductions",
  after_tax_deduction_breakdown: "Post-tax deductions",
  employer_contribution_breakdown: "Employer contributions",
} as const;
export type BreakdownKey = keyof typeof breakdownLabels;
export type HistoryCheck = Record<AmountKey, string> &
  Record<BreakdownKey, Component[]> & { employee_id: number; source_employee_name: string; provider_payment_reference?: string };
export type HistoryPeriod = {
  key: string;
  run_id?: number;
  source_digest?: string;
  start_date: string;
  end_date: string;
  pay_date: string;
  source_reference: string;
  paychecks: HistoryCheck[];
  register_totals: Record<string, string>;
  calculated_totals?: Record<string, string>;
};
export type HistoryPayload = {
  tax_year: number;
  takeover_on: string;
  provider_name: string;
  complete_history_confirmed: boolean;
  same_employer_confirmed: boolean;
  periods: HistoryPeriod[];
  identities: Record<string, { source_name: string; ssn_last4: string }>;
};
export type HistoryOnboarding = {
  id: number;
  status: "converted" | "active" | "reversed";
  provider_name: string;
  tax_year: number;
  takeover_on: string;
  converted_at: string;
  activated_at: string | null;
  reversed_at: string | null;
  reversal_reason: string | null;
  batch_id: number;
  periods: Array<{
    id: number;
    pay_date: string;
    start_date: string;
    end_date: string;
    paycheck_count: number;
    totals: Record<string, string>;
  }>;
  totals: Record<string, string>;
  source_run_ids: number[];
  can_reverse: boolean;
  employee_balances: Array<{
    employee_id: number;
    gross_pay: string;
    net_pay: string;
    federal_income_tax: string;
    social_security_taxable_wages: string;
    social_security_taxable_tips: string;
    medicare_taxable_wages: string;
  }>;
  source_files: Array<{
    id: number;
    original_filename: string;
    sha256: string;
    byte_size: number;
    verification_status: string;
  }>;
  filing_responsibilities: Array<{
    filing_type: string;
    quarter: number | null;
    responsible_party: string;
    imported_payroll_inclusion: string;
  }>;
};
export type HistoryPage = {
  company_id: number;
  enabled: boolean;
  can_manage: boolean;
  candidates: HistoryPeriod[];
  eligible_run_count: number;
  candidates_overflow: boolean;
  employees: Array<{ id: number; name: string }>;
  onboardings: HistoryOnboarding[];
};
export type HistoryPreview = {
  ready: boolean;
  errors: string[];
  digest: string;
  totals: Record<string, string> | null;
};
const path = "/admin/prior_provider_histories";
export const priorProviderHistoryApi = {
  get: () => api.get<HistoryPage>(path),
  preview: (payload: HistoryPayload) => api.post<HistoryPreview>(`${path}/preview`, { payload }),
  convert: (
    payload: HistoryPayload,
    preview_digest: string,
    idempotency_key: string,
    files: File[],
    acknowledgement: string
  ) => {
    const form = new FormData();
    form.append("payload", JSON.stringify(payload));
    form.append("preview_digest", preview_digest);
    form.append("idempotency_key", idempotency_key);
    form.append("acknowledgement", acknowledgement);
    files.forEach((file) => form.append("files[]", file));
    return api.postForm<{ onboarding: HistoryOnboarding }>(path, form);
  },
  activate: (id: number, acknowledgement: string) =>
    api.post<{ onboarding: HistoryOnboarding }>(`${path}/${id}/activate`, { acknowledgement }),
  reverse: (id: number, reason: string, acknowledgement: string) =>
    api.post<{ onboarding: HistoryOnboarding }>(`${path}/${id}/reverse`, { reason, acknowledgement }),
  sourceFile: (id: number, fileId: number) => api.getBlob(`${path}/${id}/source_files/${fileId}`),
};
