import type { ClientDocument } from '@/services/api';

export type DocumentPreviewKind = 'pdf' | 'image' | 'text' | 'html' | 'unsupported';

export interface DocumentPreviewPayload {
  kind: DocumentPreviewKind;
  objectUrl?: string;
  textContent?: string;
  htmlContent?: string;
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
      message: 'Spreadsheet preview is being prepared as a print-quality PDF. If it does not appear yet, close this window and try previewing again.',
    };
  }

  if (WORD_TYPES.has(contentType) || ['doc', 'docx'].includes(extension)) {
    return {
      kind: 'unsupported',
      message: 'Document preview is being prepared as a print-quality PDF. If it does not appear yet, close this window and try previewing again.',
    };
  }

  return {
    kind: 'unsupported',
    message: 'This file uploaded successfully, but the app could not build a preview for it yet. You can still download the original file any time.',
  };
}
