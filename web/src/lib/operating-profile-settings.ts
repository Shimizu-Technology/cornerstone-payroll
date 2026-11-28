import type { CatalogEntry, SettingValue } from '@/services/operating-profile';

// Form drafts hold list settings as comma-separated text; compare and save
// the parsed value so retyping the saved list doesn't count as an edit.
export function readSettingValue(field: CatalogEntry, draft: SettingValue): SettingValue {
  if (typeof draft !== 'string') return draft;
  if (field.type === 'nullable_string_array') return commaSeparatedItems(draft);
  if (field.type === 'uploaders' && draft !== 'all_client_users') {
    const items = commaSeparatedItems(draft);
    return items.length ? items.map(Number) : 'all_client_users';
  }
  return draft;
}

export function settingEdited(field: CatalogEntry, draft: SettingValue, baseline: SettingValue): boolean {
  return JSON.stringify(readSettingValue(field, draft)) !== JSON.stringify(baseline);
}

function commaSeparatedItems(value: string) {
  return value.split(',').map((item) => item.trim()).filter(Boolean);
}
