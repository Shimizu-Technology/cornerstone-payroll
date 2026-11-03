import api from "./api";

export const amountLabels = {
  gross_pay: "Gross pay",
  federal_income_tax: "Income tax withheld (Guam)",
  social_security_tax: "Social Security (employee)",
  medicare_tax: "Medicare (employee, incl. additional)",
  pretax_deductions: "Pre-tax deductions",
  after_tax_deductions: "Post-tax deductions",
  net_pay: "Net pay",
  employer_social_security_tax: "Social Security (employer)",
  employer_medicare_tax: "Medicare (employer)",
  employer_contributions: "Employer contributions",
  fit_taxable_wages: "Income-tax wages",
  social_security_taxable_wages: "Social Security wages",
  social_security_taxable_tips: "Social Security tips",
  medicare_taxable_wages: "Medicare wages",
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
  federal_income_tax: "Income tax withheld",
  social_security_tax: "Social Security (employee)",
  medicare_tax: "Medicare (employee)",
  deductions: "Deductions (not taxes)",
  net_pay: "Net pay",
  employer_taxes: "Employer Social Security + Medicare",
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
  /** Server-owned record of "confirm all" attestations; drafts can't change it. */
  register_attestations?: RegisterAttestation[];
};
export type RegisterAttestation = {
  actor_id: number;
  actor_name: string;
  attested_at: string;
  statement: string;
  period_count: number;
  paycheck_count: number;
  gross_pay: string;
  net_pay: string;
  period_keys: string[];
};
/** A pay date left for individual review, and why. */
export type BulkConfirmFailure = { key: string; pay_date: string; reasons: string[] };
export type BulkConfirmSummary = { period_count: number; paycheck_count: number; gross_pay: string; net_pay: string };
export const CONFIRM_ALL_ACK = "CONFIRM ALL PAY DATES MATCH THE PAID REGISTERS";
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
  payment_references?: Array<{ employee_id: number; pay_date: string; reference: string | null }>;
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
  employee_totals: Array<{
    employee_id: number;
    paycheck_count: number;
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
  employees: HistoryEmployee[];
  draft: HistoryDraft | null;
  readiness_gaps?: Array<{ employee_id: number; employee_name: string; label: string; status: string }>;
  onboardings: HistoryOnboarding[];
};
export type HistoryEmployee = { id: number; name: string; ssn_last_four: string | null };
export type HistoryDraft = {
  payload: HistoryPayload;
  step: number;
  lock_version: number;
  updated_at: string;
  updated_by_name: string;
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
  saveDraft: (payload: HistoryPayload, step: number, lock_version?: number) =>
    api.put<{ draft: HistoryDraft }>(`${path}/draft`, { payload, step, lock_version }),
  discardDraft: () => api.delete<void>(`${path}/draft`),
  confirmRegisters: (payload: HistoryPayload, step: number, lock_version: number | undefined, register_name: string, confirmed: BulkConfirmSummary) =>
    api.post<{ draft: HistoryDraft }>(`${path}/draft/confirm_registers`, {
      payload, step, lock_version, register_name, confirmed, acknowledgement: CONFIRM_ALL_ACK,
    }),
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
