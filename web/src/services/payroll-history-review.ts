import { apiClient } from '@/services/api';

export const historyResolutionLabels = {
  void_replaced: 'Voided and replaced before payment',
  void_reissued: 'Voided after payment and reissued',
  reversal_reviewed: 'Financial reversal reviewed',
  legacy_basis_accepted: 'Legacy taxable wages reviewed and accepted',
  legacy_basis_proven: 'Legacy FICA bases proven',
  imports_reconciled: 'Imported payroll reconciled',
  other: 'Other',
} as const;

type ResolutionCode = keyof typeof historyResolutionLabels;

interface PaycheckFacts {
  id: number;
  pay_date: string;
  gross_pay: string;
  social_security_tax: string | null;
  employer_social_security_tax?: string | null;
  medicare_tax: string | null;
  employer_medicare_tax?: string | null;
  missing_bases?: string[];
  employee_name?: string;
}

interface PeriodFacts {
  id: number;
  start_date: string;
  end_date: string;
  pay_date: string;
  status: string;
  gross_pay: string;
  item_count: number;
}

interface IdentifiedPaychecks {
  employee_name: string;
  paychecks: PaycheckFacts[];
}

type Subject =
  | { subject_type: 'voided_pay_period'; facts: PeriodFacts & {
      void_reason: string | null;
      checks_printed: number;
      checks_delivered_or_cleared: number;
      direct_deposits_confirmed: number;
      replacements: PeriodFacts[];
    } }
  | { subject_type: 'legacy_basis_gap'; facts: IdentifiedPaychecks }
  | { subject_type: 'reversed_payroll_item' | 'legacy_disposition'; facts: IdentifiedPaychecks & { reason: string | null } }
  | { subject_type: 'imported_history'; facts: { batch_id: number; batch_status: string; batch_source: string; paychecks: PaycheckFacts[] } };

export type HistoryReviewItem = Subject & {
  id: string;
  can_reopen: boolean;
  subject_digest: string;
  status: 'open' | 'resolved';
  resolution_codes: ResolutionCode[];
  resolution_code: ResolutionCode | null;
  resolution_reference: string | null;
  resolved_by: string | null;
  resolved_at: string | null;
};

export interface HistoryReviewList {
  data: HistoryReviewItem[];
  can_review: boolean;
}

const path = '/admin/payroll_history_review_items';

export const payrollHistoryReviewApi = {
  list: (companyId: number, year: number) =>
    apiClient.get<HistoryReviewList>(path, { year }, { companyId }),
  change: (companyId: number, year: number, item: HistoryReviewItem, change: { resolution_code: string; reference: string } | { reason: string }) =>
    apiClient.post<{ data: HistoryReviewItem }>(
      `${path}/${item.id}/${'reason' in change ? 'reopen' : 'resolve'}`,
      { year, subject_digest: item.subject_digest, ...change },
      { companyId },
    ),
};
