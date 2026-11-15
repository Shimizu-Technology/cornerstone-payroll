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

// Preview endpoints answer a spreadsheet with JSON sheet tables instead of file bytes.
export async function readSheetPreview(blob: Blob): Promise<SheetPreviewData | null> {
  if (!isJsonBlob(blob)) return null;
  const parsed = JSON.parse(await blob.text()) as { sheet_preview?: SheetPreviewData };
  return parsed.sheet_preview && Array.isArray(parsed.sheet_preview.sheets) ? parsed.sheet_preview : null;
}

export function columnLetter(index: number) {
  let letters = '';
  for (let number = index + 1; number > 0; number = Math.floor((number - 1) / 26)) {
    letters = String.fromCharCode(65 + ((number - 1) % 26)) + letters;
  }
  return letters;
}
