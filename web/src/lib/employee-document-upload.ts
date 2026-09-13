export interface DocumentUploadForm {
  title: string;
  category: string;
  notes: string;
  visible_to_client: boolean;
  requirement_id: string;
  files: File[];
}

export function selectReadinessItem(current: DocumentUploadForm, requirementId: string): DocumentUploadForm {
  return { ...current, requirement_id: requirementId, files: [] };
}

export function readinessUploadError(requirementId: string, files: File[]): string | null {
  if (files.length === 0) return 'Choose at least one employee document to upload';
  if (requirementId && files.length !== 1) return 'Choose exactly one file for a readiness item';
  return null;
}
