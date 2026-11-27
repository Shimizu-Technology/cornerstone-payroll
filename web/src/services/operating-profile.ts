import api from '@/services/api';

export type SettingValue = string | number | boolean | string[] | number[] | null;
export type Settings = Record<string, SettingValue>;

export interface CatalogEntry {
  id: string;
  label: string;
  section: string;
  storage: 'column' | 'option';
  type: 'enum' | 'nullable_enum' | 'boolean' | 'nullable_string' | 'integer' | 'nullable_string_array' | 'uploaders';
  default: SettingValue;
  allowed: string[] | boolean[] | { min: number; max: number } | null;
  what: string;
  example: string;
  effect: string;
  requires: string[];
  deprecated?: boolean;
  locked_until_milestone?: number | null;
}

export interface OperatingProfileVersion {
  id: number | null;
  effective_on: string;
  ends_on: string | null;
  version: number;
  options: Record<string, unknown>;
  offering: string;
  hours_source: string;
  intake_adapter: string | null;
  client_portal_enabled: boolean;
  employee_portal_enabled: boolean;
  persisted: boolean;
  reason: string | null;
}

export interface OperatingProfileResponse {
  as_of: string;
  client_name: string;
  lock_version: number;
  available_effective_dates: string[];
  effective: OperatingProfileVersion;
  history: OperatingProfileVersion[];
  catalog: CatalogEntry[];
  editable_keys: string[];
  locked_keys: string[];
  offering_presets: Record<string, Settings>;
  connected_source_active: boolean;
}

export const operatingProfileApi = {
  get: (companyId: number, signal?: AbortSignal) =>
    api.get<OperatingProfileResponse>(`/admin/companies/${companyId}/operating_profile`, undefined, { companyId, signal }),
  update: (companyId: number, input: { effective_on: string; changes: Settings; reason: string; lock_version: number }) =>
    api.patch<OperatingProfileResponse & { saved: OperatingProfileVersion }>(
      `/admin/companies/${companyId}/operating_profile`, input, { companyId },
    ),
};
