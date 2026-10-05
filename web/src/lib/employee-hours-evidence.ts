export interface EvidenceTotals {
  worked_hours: number; eligible_hours: number; pending_hours: number; denied_hours: number;
  issued_hours: number; committed_hours: number; exported_hours: number; held_hours: number; needs_reconciliation_hours: number;
  current_regular_hours: number; current_overtime_hours: number; frozen_regular_hours: number; frozen_overtime_hours: number; open_case_count: number; identity_review_count?: number; uncategorized_entry_count?: number;
}
export interface EvidencePeriod {
  id: string; start_date: string; end_date: string; summary: EvidenceTotals; review_required: boolean;
  detail_pagination?: { per_page: number; offset: number; counts: { entries: number; coverage_lines: number; settlement_cases: number }; next_cursor: string | null };
  entries?: Array<{ id: string; source_entry_url?: string | null; work_date: string; description: string | null; approval_status: string | null; overtime_status: string;
    regular_hours: number; overtime_hours: number; worked_hours: number; issued_hours: number; needs_reconciliation_hours: number }>;
  coverage_lines?: Array<{ id: string; source_time_entry_id: string; batch_id?: string; work_date: string;
    regular_hours: number | null; overtime_hours: number | null; total_hours: number; coverage_state: string; identity_state?: string; provenance: string;
    external_pay_period_id?: string | null; external_payroll_item_id?: string | null; payment_reference?: string | null; reason?: string | null }>;
  settlement_cases?: Array<{ public_id: string; source_time_entry_id: number; status: string; origin_reason: string; held_total_hours: string }>;
}
export interface EmployeeHoursEvidence {
  status: 'available' | 'unavailable' | 'not_linked' | 'unsupported'; message?: string; source_id: number | null;
  sources: Array<{ id: number; name: string; active: boolean; employee_identity_verified: boolean; last_synced_at?: string | null }>;
  source_workspace_url?: string | null;
  evidence?: { contract_version: string; as_of: string; employee: { id: string; payroll_integration_id: string; full_name: string };
    totals?: EvidenceTotals; periods?: EvidencePeriod[]; period?: EvidencePeriod;
    pagination?: { total_count: number; per_page: number; next_cursor: string | null } };
  payroll_records?: Array<{ payroll_item_id: number; pay_period_id: number; check_number: string | null; pay_date: string; period_description: string;
    regular_hours: number | null; overtime_hours: number | null; holiday_hours: number | null; pto_hours: number | null;
    gross_pay: number | null; net_pay: number | null; payment_evidence: { status: string; label: string; effective_on: string | null } }>;
}
