import type { ClientDocument } from '@/services/api';
import { readSheetPreview, type SheetPreviewData } from '@/lib/sheetPreview';

export type DocumentPreviewKind = 'pdf' | 'image' | 'text' | 'sheet' | 'unsupported';

export interface DocumentPreviewPayload {
  kind: DocumentPreviewKind;
  objectUrl?: string;
  textContent?: string;
  sheet?: SheetPreviewData;
  message?: string;
}

const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp']);
const TEXT_TYPES = new Set(['text/plain']);
const SPREADSHEET_TYPES = new Set([
  'text/csv',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
]);
const WORD_TYPES = new Set([
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
]);
function extensionOf(fileName: string) {
  return fileName.split('.').pop()?.toLowerCase() || '';
}

export async function prepareDocumentPreview(
  document: Pick<ClientDocument, 'content_type' | 'file_name'>,
  blob: Blob
): Promise<DocumentPreviewPayload> {
  const contentType = blob.type || document.content_type;
  const extension = extensionOf(document.file_name);

  // The server answers .xlsx and .csv previews with sheet tables, or the reason it can't.
  const sheetResult = await readSheetPreview(blob);
  if (sheetResult) {
    return 'sheet' in sheetResult ? { kind: 'sheet', sheet: sheetResult.sheet } : { kind: 'unsupported', message: sheetResult.unavailable };
  }

  if (contentType === 'application/pdf' || extension === 'pdf') {
    return { kind: 'pdf', objectUrl: URL.createObjectURL(blob) };
  }

  if (IMAGE_TYPES.has(contentType)) {
    return { kind: 'image', objectUrl: URL.createObjectURL(blob) };
  }

  if (TEXT_TYPES.has(contentType) || extension === 'txt') {
    return { kind: 'text', textContent: await blob.text() };
  }

  if (SPREADSHEET_TYPES.has(contentType) || ['csv', 'xls', 'xlsx'].includes(extension)) {
    return {
      kind: 'unsupported',
      message: extension === 'xls'
        ? 'Older Excel files (.xls) can’t be previewed here yet. Download the file to open it in Excel.'
        : 'This spreadsheet can’t be previewed here. Download the file to open it in Excel.',
    };
  }

  if (WORD_TYPES.has(contentType) || ['doc', 'docx'].includes(extension)) {
    return {
      kind: 'unsupported',
      message: 'Word documents can’t be previewed here yet. Download the file to open it in Word.',
    };
  }

  return {
    kind: 'unsupported',
    message: 'This file uploaded successfully, but the app could not build a preview for it yet. You can still download the original file any time.',
  };
}
