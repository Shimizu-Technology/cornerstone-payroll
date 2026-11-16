import type { ImportSourceDocument, MosaSourceRow } from '@/services/api';

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
