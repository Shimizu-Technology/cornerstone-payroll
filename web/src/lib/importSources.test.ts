import { describe, expect, it } from 'vitest';
import { sameSourceFiles } from './importSources';
import type { ImportSourceDocument } from '@/services/api';

const file = (source_role: string, sha256: string | null | undefined, id = 1): ImportSourceDocument => ({ id, source_role, filename: `${source_role}.bin`, content_type: 'application/octet-stream', byte_size: 1, sha256 });

describe('sameSourceFiles', () => {
  it('matches the same file per role, whatever the record IDs or order', () => {
    expect(sameSourceFiles([file('revel_hours', 'a', 1), file('supplemental_workbook', 'b', 2)], [file('supplemental_workbook', 'b', 8), file('revel_hours', 'a', 9)])).toBe(true);
  });

  it('does not match a changed, added or removed file', () => {
    expect(sameSourceFiles([file('revel_hours', 'a')], [file('revel_hours', 'c')])).toBe(false);
    expect(sameSourceFiles([file('revel_hours', 'a')], [file('revel_hours', 'a'), file('supplemental_workbook', 'b')])).toBe(false);
    expect(sameSourceFiles([file('revel_hours', 'a'), file('supplemental_workbook', 'b')], [file('revel_hours', 'a')])).toBe(false);
  });

  it('does not match when a fingerprint is missing or there are no files', () => {
    expect(sameSourceFiles([file('revel_hours', null)], [file('revel_hours', null)])).toBe(false);
    expect(sameSourceFiles([file('revel_hours', undefined)], [file('revel_hours', undefined)])).toBe(false);
    expect(sameSourceFiles([], [])).toBe(false);
    expect(sameSourceFiles(undefined, undefined)).toBe(false);
  });
});
