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

export function isCurrentEmployeeDocumentRequest(requestId: number, latestRequestId: number): boolean {
  return requestId === latestRequestId;
}

export function reconcileEmployeeDocumentLoads<Documents, Readiness>(
  documentsResult: PromiseSettledResult<Documents>,
  readinessResult: PromiseSettledResult<Readiness>,
): { documents?: Documents; readiness?: Readiness; error: string | null } {
  const loadErrors: string[] = [];
  if (documentsResult.status === 'rejected') {
    loadErrors.push(documentsResult.reason instanceof Error ? documentsResult.reason.message : 'Employee documents could not be loaded');
  }
  if (readinessResult.status === 'rejected') {
    const reason = readinessResult.reason instanceof Error
      ? readinessResult.reason.message
      : typeof readinessResult.reason === 'string' && readinessResult.reason.trim()
        ? readinessResult.reason.trim()
        : 'Try again or contact support.';
    loadErrors.push(`Payroll readiness could not be loaded: ${reason}`);
  }

  return {
    documents: documentsResult.status === 'fulfilled' ? documentsResult.value : undefined,
    readiness: readinessResult.status === 'fulfilled' ? readinessResult.value : undefined,
    error: loadErrors.join(' ') || null,
  };
}
