import type { EmployeePayrollField, PayrollFieldDefinition, PayrollFieldKind, PayrollFieldTaxTreatment, PayrollFieldAmountType, PayrollFieldCategory, PayrollFieldReportingGroup } from '@/types';

export const payItemGroups: Array<{ kind: PayrollFieldKind; title: string; singular: string; action: string; description: string; className: string }> = [
  { kind: 'addition', title: 'Additions', singular: 'addition', action: 'Add addition', description: 'Extra pay and reimbursements added to this person’s paycheck.', className: 'border-emerald-200 bg-emerald-50/50' },
  { kind: 'deduction', title: 'Deductions', singular: 'deduction', action: 'Add deduction', description: 'Amounts withheld from this person’s paycheck.', className: 'border-rose-200 bg-rose-50/50' },
  { kind: 'employer_contribution', title: 'Employer contributions', singular: 'contribution', action: 'Add employer contribution', description: 'Employer-paid amounts that do not reduce take-home pay.', className: 'border-indigo-200 bg-indigo-50/50' },
];

export function payItemTreatments(kind: PayrollFieldKind): Array<{ value: PayrollFieldTaxTreatment; label: string }> {
  if (kind === 'addition') return [
    { value: 'taxable_addition', label: 'Taxable addition' },
    { value: 'non_taxable_addition', label: 'Non-taxable reimbursement/addition' },
  ];
  if (kind === 'deduction') return [
    { value: 'post_tax_deduction', label: 'Post-tax deduction' },
    { value: 'pre_tax_deduction', label: 'Pre-tax deduction' },
  ];
  return [{ value: 'employer_contribution', label: 'Employer contribution' }];
}

export function payItemAmount(assignment: EmployeePayrollField, field: Pick<PayrollFieldDefinition, 'amount_type' | 'default_amount' | 'default_percentage'>): number | null {
  if (field.amount_type === 'manual') return assignment.amount ?? field.default_amount ?? null;
  return field.amount_type === 'percentage'
    ? assignment.percentage ?? field.default_percentage ?? 0
    : assignment.amount ?? field.default_amount ?? 0;
}

export function payItemStatus(assignment: EmployeePayrollField, fieldActive: boolean, today: string): string {
  if (!fieldActive) return 'Archived field';
  if (!assignment.active) return 'Paused';
  if (assignment.end_date && assignment.end_date < today) return `Ended ${assignment.end_date}`;
  if (assignment.start_date && assignment.start_date > today) return `Starts ${assignment.start_date}`;
  return 'Active';
}

export interface PayItemDraft {
  kind: PayrollFieldKind;
  source: 'new' | 'existing';
  scope: 'employee_only' | 'client_wide';
  assignmentId?: number;
  fieldId?: number;
  name: string;
  treatment: PayrollFieldTaxTreatment;
  category: PayrollFieldCategory;
  reportingGroup: PayrollFieldReportingGroup | '';
  amountType: PayrollFieldAmountType;
  amount: string;
  useDefault: boolean;
  startDate: string;
  endDate: string;
  notes: string;
  payee: string;
  reference: string;
  active: boolean;
  dirty: boolean;
  duplicateAcknowledged?: boolean;
}

export function newPayItemDraft(kind: PayrollFieldKind): PayItemDraft {
  return { kind, source: 'new', scope: 'employee_only', name: '', treatment: payItemTreatments(kind)[0].value,
    category: 'other', reportingGroup: '', amountType: 'fixed', amount: '', useDefault: false,
    startDate: '', endDate: '', notes: '', payee: '', reference: '', active: true, dirty: false };
}
