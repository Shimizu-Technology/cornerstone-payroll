import api from './api';

// Client profitability (api/app/controllers/api/v1/admin/client_profitability_controller.rb).
// The report is organization-wide, so requests never carry the selected
// client's X-Company-Id.
const NO_COMPANY = { companyId: null } as const;
const BASE = '/admin/client_profitability';

export interface TaxConnection {
  connected: boolean;
  missing: string[];
  problem: string | null;
  tax_host: string | null;
}

export interface WorkHourImportStatus {
  id: number;
  status: 'queued' | 'running' | 'succeeded' | 'failed';
  trigger: 'manual' | 'scheduled';
  range_start: string;
  range_end: string;
  requested_by: string | null;
  created_at: string | null;
  started_at: string | null;
  finished_at: string | null;
  row_count: number;
  total_hours: string;
  pending_entries: number;
  denied_entries: number;
  open_clock_entries: number;
  error_code: string | null;
  error_message: string | null;
}

export interface NamedOption { id: number; name: string }

export interface ProfitabilityOverview {
  connection: TaxConnection;
  settings: {
    practice_company_id: number | null;
    finance_book_id: number | null;
    effective_finance_book_id: number | null;
    tax_prep_service_names: string[];
  };
  options: { companies: NamedOption[]; finance_books: NamedOption[]; service_names: string[] };
  imports: WorkHourImportStatus[];
  has_hours: boolean;
  needs_linking: { clients: number; staff: number };
}

export interface LinkSuggestion {
  disposition: 'company' | 'internal' | 'employee';
  company_id?: number;
  employee_id?: number;
  label: string;
  match: 'exact' | 'similar' | 'internal';
}

export interface TaxClientEntry {
  tax_client_id: number;
  name: string;
  hours: string;
  last_worked_on: string | null;
  internal_in_tax: boolean;
  handled_automatically: boolean;
  link: { disposition: 'company' | 'internal'; company_id: number | null; company_name: string | null } | null;
  suggestion: LinkSuggestion | null;
}

export interface TaxStaffEntry {
  tax_user_id: number;
  email: string | null;
  hours: string;
  link: { disposition: 'employee' | 'no_payroll'; employee_id: number | null; employee_name: string | null; in_practice_company: boolean } | null;
  suggestion: LinkSuggestion | null;
}

export interface LinkQueueData {
  clients: TaxClientEntry[];
  staff: TaxStaffEntry[];
  companies: NamedOption[];
  employees: Array<NamedOption & { status: string }>;
}

export interface ProfitabilityCategory { category: string; task: string | null; hours: string; pending_hours: string }

export interface ProfitabilityPerson {
  tax_user_id: number;
  name: string;
  linked: boolean;
  hours: string;
  approved_hours: string;
  pending_hours: string;
  cost: string;
  categories: ProfitabilityCategory[];
}

export interface ProfitabilityLine {
  key: string;
  kind: 'company' | 'overhead' | 'unlinked_client' | 'no_client';
  company_id: number | null;
  tax_client_id: number | null;
  name: string;
  hours: string;
  pending_hours: string;
  direct_cost: string;
  overhead_cost: string;
  cost: string;
  fees: string;
  tax_prep_fees: string;
  other_fees: string;
  margin: string;
  margin_percent: string | null;
  effective_rate: string | null;
  people: ProfitabilityPerson[];
  spread?: boolean;
}

export interface ProfitabilityTotals {
  hours: string;
  pending_hours: string;
  cost: string;
  fees: string;
  tax_prep_fees: string;
  other_fees: string;
  margin: string;
  margin_percent: string | null;
  effective_rate: string | null;
}

export interface ProfitabilityReport {
  period: { from: string; through: string; start_date: string; end_date: string; label: string };
  options: { cost_pending: boolean; spread_overhead: boolean };
  practice_company: NamedOption | null;
  finance_book: NamedOption | null;
  coverage: { missing_months: string[]; missing_month_labels: string[]; last_refreshed_at: string | null; pending_hours: string };
  clients: ProfitabilityLine[];
  overhead: ProfitabilityLine | null;
  unassigned: ProfitabilityLine[];
  unlinked_fees: { fees: string; tax_prep_fees: string };
  unallocated_costs: Array<{ employee_id: number | null; name: string; reason: 'not_linked' | 'no_hours' | 'unlinked_paychecks'; cost: string }>;
  staff: Array<{
    tax_user_id: number;
    name: string;
    status: 'employee' | 'no_payroll' | 'not_linked';
    hours: string;
    pending_hours: string;
    pay: string | null;
    employer_taxes: string | null;
    employer_contributions: string | null;
    cost: string | null;
    cost_per_hour: string | null;
  }>;
  totals: ProfitabilityTotals;
  connection: TaxConnection;
}

export interface ReportQuery {
  from: string;
  through: string;
  cost_pending: boolean;
  spread_overhead: boolean;
}

export const clientProfitabilityApi = {
  overview: () => api.get<ProfitabilityOverview>(BASE, undefined, NO_COMPANY),
  updateSettings: (data: { practice_company_id?: number | null; finance_book_id?: number | null; tax_prep_service_names?: string[] }) =>
    api.patch<ProfitabilityOverview>(`${BASE}/settings`, data, NO_COMPANY),
  refresh: (from: string, through: string) =>
    api.post<{ import: WorkHourImportStatus }>(`${BASE}/refresh`, { from, through }, NO_COMPANY),
  importStatus: (id: number) => api.get<{ import: WorkHourImportStatus }>(`${BASE}/imports/${id}`, undefined, NO_COMPANY),
  links: () => api.get<LinkQueueData>(`${BASE}/links`, undefined, NO_COMPANY),
  linkClient: (taxClientId: number, data: { disposition: 'company' | 'internal'; company_id?: number; tax_client_name?: string }) =>
    api.put<{ ok: true }>(`${BASE}/client_links/${taxClientId}`, data, NO_COMPANY),
  unlinkClient: (taxClientId: number) => api.delete<void>(`${BASE}/client_links/${taxClientId}`, NO_COMPANY),
  linkStaff: (taxUserId: number, data: { disposition: 'employee' | 'no_payroll'; employee_id?: number; email?: string | null }) =>
    api.put<{ ok: true }>(`${BASE}/staff_links/${taxUserId}`, data, NO_COMPANY),
  unlinkStaff: (taxUserId: number) => api.delete<void>(`${BASE}/staff_links/${taxUserId}`, NO_COMPANY),
  report: (query: ReportQuery) => api.get<ProfitabilityReport>(`${BASE}/report`, { ...query }, NO_COMPANY),
  exportCsv: (query: ReportQuery) => api.getBlobWithParams(`${BASE}/export`, { ...query }, NO_COMPANY),
};
