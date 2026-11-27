import type { CompanyListItem, ImportSourceDocument, MosaSourceRow, PayrollIntakeDescriptor, PayrollIntakeFileSlot } from '@/services/api';

// Default MoSa descriptor fallback used only when a caller or legacy test
// fixture omits the server-serialized descriptor payload.
export const DEFAULT_MOSA_DESCRIPTOR: PayrollIntakeDescriptor = {
  key: 'mosa_revel',
  label: 'Revel hours + Cornerstone workbook',
  source_label: 'MoSa Revel hours and payroll changes',
  parser_version: 'mosa_revel:v1',
  extraction: 'deterministic',
  accepts_pasted_text: false,
  tracks_reviewed_hours: true,
  employee_match: 'name_fuzzy',
  idempotency: 'files_period_roster_loans_and_workweek',
  reports_overtime: true,
  tips_default: 'paid_in_check',
  overtime_mode: 'source_reports',
  workweek_alignment: 'warn_if_offset',
  required_sources: ['revel_hours', 'supplemental_workbook'],
  files: [
    {
      role: 'revel_hours',
      label: 'Revel hours PDF',
      hint: 'The original Revel report. Its regular and overtime hours are imported; Revel pay rates and pay amounts are ignored. Its dates must match this payroll.',
      accept: ['.pdf'],
      content_type: 'application/pdf',
      max: 1,
      required: true,
      required_by_default: true,
      waivable: null,
      portal_role: 'revel_payroll',
      portal_label: 'Revel hours report (PDF)',
      portal_hint: 'Hours worked, including overtime, from Revel.',
      supports_link: false,
      provides: ['regular_hours', 'overtime_hours'],
    },
    {
      role: 'supplemental_workbook',
      label: 'Tips & loans workbook',
      hint: 'The Cornerstone change workbook with tips, loans, owner pay and one-time items.',
      accept: ['.xlsx', '.xls'],
      content_type: null,
      max: 1,
      required: true,
      required_by_default: true,
      waivable: 'No tips or loans this period',
      portal_role: 'changes_workbook',
      portal_label: 'Tips & loans workbook (Excel)',
      portal_hint: 'Tips to report and loan deductions for this payroll.',
      supports_link: true,
      provides: ['reported_tips', 'tips_already_paid', 'loan_one_time', 'loan_installment', 'one_time_earnings', 'owner_pay'],
    },
  ],
  portal: {
    submittable: true,
    role_map: {
      revel_payroll: 'revel_hours',
      changes_workbook: 'supplemental_workbook',
    },
  },
};

export const DEFAULT_SPIKE_DESCRIPTOR: PayrollIntakeDescriptor = {
  key: 'spike_email',
  label: 'Spike Coffee Roasters email',
  source_label: 'Spike Coffee Roasters email',
  parser_version: 'spike_email:v3',
  extraction: 'text_and_ai',
  accepts_pasted_text: true,
  tracks_reviewed_hours: false,
  employee_match: 'name_fuzzy',
  idempotency: 'files_and_workweek',
  reports_overtime: false,
  tips_default: 'already_paid_out',
  overtime_mode: 'weekly_split',
  workweek_alignment: 'aligned',
  required_sources: [],
  files: [],
  portal: {
    submittable: false,
    role_map: {},
  },
};

export const DEFAULT_CORNERSTONE_WORKBOOK_DESCRIPTOR: PayrollIntakeDescriptor = {
  key: 'cornerstone_workbook',
  label: 'Cornerstone workbook',
  source_label: 'Cornerstone universal payroll workbook',
  parser_version: 'cornerstone_workbook:v1',
  extraction: 'deterministic',
  accepts_pasted_text: false,
  tracks_reviewed_hours: false,
  employee_match: 'employee_id',
  idempotency: 'files_and_workweek',
  reports_overtime: false,
  tips_default: 'paid_in_check',
  overtime_mode: 'weekly_split',
  workweek_alignment: 'aligned',
  required_sources: ['cornerstone_workbook'],
  files: [
    {
      role: 'cornerstone_workbook',
      label: 'Cornerstone workbook',
      hint: 'Upload the completed Cornerstone payroll workbook (.xlsx or .csv) pre-filled with active Employee IDs.',
      accept: ['.xlsx', '.csv'],
      content_type: null,
      max: 1,
      required: true,
      required_by_default: true,
      waivable: null,
      portal_role: 'payroll_workbook',
      portal_label: 'Cornerstone payroll workbook (.xlsx or .csv)',
      portal_hint: 'Download this period’s pre-filled Excel or CSV template, enter hours, PTO, holiday, tips, bonuses, one-time items, and loans, then upload it here.',
      supports_link: false,
      template_formats: ['xlsx', 'csv'],
      provides: [
        'week1_hours',
        'week2_hours',
        'regular_hours',
        'overtime_hours',
        'pto_hours',
        'holiday_hours',
        'reported_tips',
        'tips_already_paid',
        'bonus',
        'one_time_earnings',
        'one_time_deductions',
        'loan_deduction',
      ],
    },
  ],
  portal: {
    submittable: true,
    role_map: {
      payroll_workbook: 'cornerstone_workbook',
    },
  },
};

export function acceptStringForSlot(slot: PayrollIntakeFileSlot, includeContentType = false): string {
  const parts: string[] = [];
  if (includeContentType && slot.content_type) parts.push(slot.content_type);
  slot.accept.forEach((ext) => {
    if (!parts.includes(ext)) parts.push(ext);
  });
  return parts.join(',');
}

export function acceptMapForDescriptor(descriptor?: PayrollIntakeDescriptor | null): Record<string, string> {
  if (!descriptor?.files?.length) return MOSA_SOURCE_ACCEPT;
  return Object.fromEntries(descriptor.files.map((slot) => [slot.role, acceptStringForSlot(slot)]));
}

export function pickersForDescriptor(descriptor?: PayrollIntakeDescriptor | null): Array<{
  role: string;
  label: string;
  hint: string;
  accept: string;
  required: boolean;
  waivable: string | null;
}> {
  const effective = descriptor?.files?.length ? descriptor : DEFAULT_MOSA_DESCRIPTOR;
  return effective.files.map((slot) => ({
    role: slot.role,
    label: slot.label,
    hint: slot.hint || '',
    accept: acceptStringForSlot(slot),
    required: slot.required,
    waivable: slot.waivable || null,
  }));
}

export function portalRoleLabel(role: string, descriptor?: PayrollIntakeDescriptor | null): string {
  if (role === 'attachment') return 'Attachment';
  const slot = descriptor?.files?.find((candidate) => candidate.portal_role === role);
  if (slot) {
    if (role === 'revel_payroll') return 'Revel payroll PDF';
    if (role === 'changes_workbook') return 'Changes workbook';
    return slot.portal_label || slot.label;
  }
  if (role === 'revel_payroll') return 'Revel payroll PDF';
  if (role === 'changes_workbook') return 'Changes workbook';
  return role.replace(/_/g, ' ').replace(/\b\w/g, (ch) => ch.toUpperCase());
}

export function hasPortalSubmittableAdapter(company?: Pick<CompanyListItem, 'portal_payroll_files_enabled' | 'payroll_intake_adapters' | 'payroll_intake_source_types'> | null): boolean {
  if (!company) return false;
  if (typeof company.portal_payroll_files_enabled === 'boolean') return company.portal_payroll_files_enabled;
  if (company.payroll_intake_adapters?.length) {
    return company.payroll_intake_adapters.some((adapter) => adapter.portal?.submittable);
  }
  return Boolean(company.payroll_intake_source_types?.some((key) => key === 'mosa_revel' || key === 'cornerstone_workbook'));
}

export function intakeAdaptersForPayPeriod(
  adapters?: PayrollIntakeDescriptor[] | null,
  sourceTypes?: string[] | null,
): PayrollIntakeDescriptor[] {
  if (adapters?.length) return adapters;
  return (sourceTypes || []).flatMap((key) => {
    if (key === 'mosa_revel') return [DEFAULT_MOSA_DESCRIPTOR];
    if (key === 'spike_email') return [DEFAULT_SPIKE_DESCRIPTOR];
    if (key === 'cornerstone_workbook') return [DEFAULT_CORNERSTONE_WORKBOOK_DESCRIPTOR];
    return [];
  });
}

export function intakeMenuLabel(descriptor: PayrollIntakeDescriptor): string {
  if (descriptor.key === 'mosa_revel') return 'Import (MoSa)';
  if (descriptor.key === 'spike_email') return 'Import Spike Email';
  if (descriptor.key === 'cornerstone_workbook') return 'Import Cornerstone Workbook';
  return `Import (${descriptor.label})`;
}

export function templateFormatsForSlot(slot?: PayrollIntakeFileSlot | null): Array<'xlsx' | 'csv'> {
  return (slot?.template_formats || []).filter((format): format is 'xlsx' | 'csv' => format === 'xlsx' || format === 'csv');
}

// The retained files import review can show beside the review: the Revel
// hours PDF and the optional payroll change workbook.
export function importSourceFiles(documents?: ImportSourceDocument[]) {
  const files = documents || [];
  return {
    pdf: files.find((file) => file.source_role === 'revel_hours')
      || files.find((file) => file.content_type === 'application/pdf' || /\.pdf$/i.test(file.filename)),
    workbook: files.find((file) => file.source_role === 'supplemental_workbook'),
  };
}

// File picker types for each MoSa source file.
export const MOSA_SOURCE_ACCEPT: Record<string, string> = {
  revel_hours: '.pdf',
  supplemental_workbook: '.xlsx,.xls',
};

export const defaultDisposition = (row: MosaSourceRow): MosaSourceRow['disposition'] => (row.row_kind === 'matched' && row.errors.length === 0 ? 'included' : 'pending');

// A new package (a file added, or matching run again) gets new row IDs. Keep the
// outcome staff already chose for the same source row, unless it can no longer apply.
export function carryRowOutcomes(previous: MosaSourceRow[], next: MosaSourceRow[]): MosaSourceRow[] {
  const key = (row: MosaSourceRow) => `${row.row_kind}|${row.source_employee_name}|${row.employee_id ?? ''}`;
  const chosen = new Map(previous.map((row) => [key(row), row]));
  return next.map((row) => {
    const kept = chosen.get(key(row));
    const fallback = defaultDisposition(row);
    if (!kept || kept.disposition === 'pending' || (kept.disposition === 'included' && fallback !== 'included')) return { ...row, disposition: fallback };
    return { ...row, disposition: kept.disposition, disposition_reason: kept.disposition_reason, target_pay_period_id: kept.target_pay_period_id };
  });
}

// Whether two reviews were matched from the same retained files, compared by
// each file's SHA-256 per role. A rematch of unchanged files can get a new
// package, so IDs alone can't tell. False when any file has no fingerprint.
export function sameSourceFiles(a?: ImportSourceDocument[], b?: ImportSourceDocument[]): boolean {
  const fingerprint = (documents?: ImportSourceDocument[]) => {
    if (!documents?.length || documents.some((document) => !document.sha256)) return null;
    return documents.map((document) => `${document.source_role}:${document.sha256}`).sort().join('|');
  };
  const left = fingerprint(a);
  return left !== null && left === fingerprint(b);
}

const WARNING_TITLES: Record<string, string> = {
  workbook_period_end_differs: 'The workbook’s period end differs from Revel',
  pay_period_workweek_offset: 'This pay period and the overtime workweek start on different days',
  legacy_mosa_workbook: 'Older MoSa workbook format',
  zero_workbook_tips: 'The workbook’s tips total $0',
  client_no_tips_or_loans: 'The client chose no tips or loans this period',
  missing_workbook: 'The tips & loans workbook isn’t included',
  duplicate_source: 'These files were already previewed for this payroll',
  no_rows_detected: 'No payroll rows were found',
  unverified_source_not_kept: 'A file saved before verification was not kept',
};

// One line for a notice; the full message stays available underneath.
export function noticeTitle(code: string | undefined, message: string): string {
  if (code && WARNING_TITLES[code]) return WARNING_TITLES[code];
  const firstSentence = message.match(/^.*?[.!?](?=\s|$)/)?.[0] || message;
  return firstSentence.length > 110 ? `${firstSentence.slice(0, 107).trimEnd()}…` : firstSentence;
}

// SHA-256 of a chosen file, to tell whether it is the same file an import
// already holds. Null when the browser cannot hash it.
export async function fileSha256(file: File): Promise<string | null> {
  try {
    const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  } catch {
    return null;
  }
}
