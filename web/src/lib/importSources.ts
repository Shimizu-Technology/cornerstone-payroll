import type { ImportSourceDocument } from '@/services/api';

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
