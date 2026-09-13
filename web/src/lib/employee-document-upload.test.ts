import { describe, expect, it } from 'vitest';
import { readinessUploadError, selectReadinessItem } from './employee-document-upload';

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
});
