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
