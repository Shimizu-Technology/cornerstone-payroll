import { expect, it } from 'vitest';
import { prepareDocumentPreview } from './documentPreview';

const sheetPreview = { sheet_count: 1, truncated_sheets: false, limits: { sheets: 10, rows: 500, columns: 50 },
  sheets: [{ name: 'hours', columns: 2, truncated_rows: false, truncated_columns: false, rows: [{ number: 1, cells: ['Ava', '40'] }] }] };

it('turns a sheet preview response into sheet tables', async () => {
  const blob = new Blob([JSON.stringify({ sheet_preview: sheetPreview })], { type: 'application/json; charset=utf-8' });

  const payload = await prepareDocumentPreview({ file_name: 'hours.xlsx', content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }, blob);

  expect(payload).toEqual({ kind: 'sheet', sheet: sheetPreview });
});

it('never promises a PDF that is not coming for spreadsheets or Word files', async () => {
  const xls = await prepareDocumentPreview({ file_name: 'old.xls', content_type: 'application/vnd.ms-excel' }, new Blob(['x'], { type: 'application/vnd.ms-excel' }));
  const docx = await prepareDocumentPreview({ file_name: 'notes.docx', content_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }, new Blob(['x']));

  expect(xls).toEqual({ kind: 'unsupported', message: expect.stringContaining('Older Excel files (.xls)') });
  expect(docx).toEqual({ kind: 'unsupported', message: expect.stringContaining('Word documents can’t be previewed here yet') });
  expect(`${xls.message} ${docx.message}`).not.toMatch(/PDF/);
});

it('explains a damaged spreadsheet inside the preview instead of failing', async () => {
  const blob = new Blob([JSON.stringify({ sheet_preview: null, sheet_preview_unavailable: 'This spreadsheet could not be read.' })], { type: 'application/json' });

  const payload = await prepareDocumentPreview({ file_name: 'damaged.xlsx', content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }, blob);

  expect(payload).toEqual({ kind: 'unsupported', message: 'This spreadsheet could not be read.' });
});
