import { describe, expect, it } from 'vitest';
import {
  isCurrentEmployeeDocumentRequest,
  isCurrentEmployeeDocumentScope,
  readinessUploadError,
  reconcileEmployeeDocumentLoads,
  selectReadinessItem,
} from './employee-document-upload';

describe('employee document readiness upload state', () => {
  it('clears previously selected files when a readiness item is selected', () => {
    const files = [{ name: 'first.pdf' }, { name: 'second.pdf' }] as File[];
    const next = selectReadinessItem({
      title: '',
      category: 'employee_onboarding',
      notes: '',
      visible_to_client: true,
      requirement_id: '',
      files,
    }, '42');

    expect(next.requirement_id).toBe('42');
    expect(next.files).toEqual([]);
  });

  it('rejects multiple files before a readiness upload is sent', () => {
    const files = [{ name: 'first.pdf' }, { name: 'second.pdf' }] as File[];

    expect(readinessUploadError('42', files)).toBe('Choose exactly one file for a readiness item');
    expect(readinessUploadError('', files)).toBeNull();
  });

  it('retains successful documents when payroll readiness fails to load', () => {
    const documents = [{ id: 42, title: 'Signed tax form' }];
    const result = reconcileEmployeeDocumentLoads(
      { status: 'fulfilled', value: documents },
      { status: 'rejected', reason: new Error('Readiness service unavailable') },
    );

    expect(result.documents).toBe(documents);
    expect(result.readiness).toBeNull();
    expect(result.error).toBe('Payroll readiness could not be loaded: Readiness service unavailable');
  });

  it('uses a distinct readiness fallback for non-error rejections', () => {
    const result = reconcileEmployeeDocumentLoads(
      { status: 'fulfilled', value: [] },
      { status: 'rejected', reason: undefined },
    );

    expect(result.error).toBe('Payroll readiness could not be loaded: Try again or contact support.');
  });

  it('rejects an employee-document response superseded by a newer request', () => {
    expect(isCurrentEmployeeDocumentRequest(8, 9)).toBe(false);
    expect(isCurrentEmployeeDocumentRequest(9, 9)).toBe(true);
  });

  it('rejects employee-document work captured for a different employee', () => {
    expect(isCurrentEmployeeDocumentScope(17, 18)).toBe(false);
    expect(isCurrentEmployeeDocumentScope(18, 18)).toBe(true);
  });
});
