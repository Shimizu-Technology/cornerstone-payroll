// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import type { ImportPreviewResponse } from '@/services/api';

vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
}));
afterEach(cleanup);

it('keeps retained evidence in the import company even from an unscoped route', async () => {
  const preview: ImportPreviewResponse = {
    import_id: 30,
    source_package: { id: 1, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    portal_source: { selection_id: 1, submission_id: 20, revision: 2, period_id: 90, current: true, no_changes: true, changes: [] },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: false, tips_paid_out_from_tips: false, source_rows: [] },
  };
  render(<MemoryRouter initialEntries={['/settings/payroll-submissions/90']}>
    <ImportModal open payPeriodId={9} companyId={7} initialPreview={preview} onOpenChange={vi.fn()} onImportComplete={vi.fn()} />
  </MemoryRouter>);
  expect((await screen.findByRole('link', { name: 'Open retained portal submission' })).getAttribute('href')).toBe('/companies/7/payroll-submissions/90');
});
