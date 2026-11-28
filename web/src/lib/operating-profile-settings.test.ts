import { describe, expect, it } from 'vitest';
import type { CatalogEntry } from '@/services/operating-profile';
import { readSettingValue, settingEdited } from './operating-profile-settings';

const entry = (type: string): CatalogEntry => ({
  id: 'intake.required_sources', label: 'Required intake sources', section: 'intake', storage: 'option',
  type, default: null, allowed: null, what: '', example: '', effect: '', requires: [],
} as unknown as CatalogEntry);

describe('settingEdited', () => {
  it('treats a list retyped back to its saved value as unedited', () => {
    const field = entry('nullable_string_array');
    expect(settingEdited(field, ' revel_pdf, workbook ', ['revel_pdf', 'workbook'])).toBe(false);
    expect(settingEdited(field, 'revel_pdf', ['revel_pdf', 'workbook'])).toBe(true);
  });

  it('parses uploader ids the same way the save does', () => {
    const field = entry('uploaders');
    expect(readSettingValue(field, ' 42, , 43 ')).toEqual([42, 43]);
    expect(settingEdited(field, '42, 43', [42, 43])).toBe(false);
    expect(settingEdited(field, '', 'all_client_users')).toBe(false);
  });

  it('compares non-text values directly', () => {
    expect(settingEdited(entry('enum'), 'manual', 'manual')).toBe(false);
    expect(settingEdited(entry('enum'), 'connected_app', 'manual')).toBe(true);
  });
});
