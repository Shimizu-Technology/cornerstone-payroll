// Sheet tables returned by the server's read-only spreadsheet preview.
export interface SheetPreviewSheet {
  name: string;
  columns: number;
  rows: { number: number; cells: (string | null)[] }[];
  truncated_rows: boolean;
  truncated_columns: boolean;
}

export interface SheetPreviewData {
  sheets: SheetPreviewSheet[];
  sheet_count: number;
  truncated_sheets: boolean;
  limits: { sheets: number; rows: number; columns: number };
}

export function isJsonBlob(blob: Blob) {
  return blob.type.toLowerCase().startsWith('application/json');
}

export type SheetPreviewResult = { sheet: SheetPreviewData } | { unavailable: string };

// Preview endpoints answer a spreadsheet with JSON sheet tables instead of file
// bytes, or with the reason a damaged or unsupported file can't be shown.
export async function readSheetPreview(blob: Blob): Promise<SheetPreviewResult | null> {
  if (!isJsonBlob(blob)) return null;
  const parsed = JSON.parse(await blob.text()) as { sheet_preview?: SheetPreviewData | null; sheet_preview_unavailable?: string };
  if (parsed.sheet_preview && Array.isArray(parsed.sheet_preview.sheets)) return { sheet: parsed.sheet_preview };
  if (parsed.sheet_preview_unavailable) return { unavailable: parsed.sheet_preview_unavailable };
  return null;
}

export function columnLetter(index: number) {
  let letters = '';
  for (let number = index + 1; number > 0; number = Math.floor((number - 1) / 26)) {
    letters = String.fromCharCode(65 + ((number - 1) % 26)) + letters;
  }
  return letters;
}
