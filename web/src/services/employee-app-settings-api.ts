import { apiClient } from '@/services/api';

export interface HelpContact {
  name: string;
  role: string | null;
  phone: string | null;
  email: string | null;
  text_ok: boolean;
}

export interface EmployeeAppBranding {
  display_name: string | null;
  app_name: string | null;
  primary_color: string | null;
  accent_color: string | null;
  show_main_phone: boolean;
  logo: { content_type: string; byte_size: number; digest: string } | null;
  external_logo_url: string | null;
}

export interface EmployeeAppSettings {
  company_id: number;
  company_name: string;
  branding: EmployeeAppBranding;
  main_phone: string | null;
  subdomain: { slug: string | null; host: string | null };
  help_contacts: HelpContact[];
  max_help_contacts: number;
  logo_limits: { max_bytes: number; content_types: string[] };
}

export interface BrandingUpdate {
  display_name: string;
  app_name: string;
  primary_color: string;
  accent_color: string;
  show_main_phone: boolean;
}

type Audience = 'staff' | 'client';

// Staff use the admin namespace and client users the client namespace, so
// each side is authorized and audited as itself.
function base(audience: Audience): string {
  return audience === 'client' ? '/client/employee_app_settings' : '/admin/employee_app_settings';
}

export function employeeAppSettingsApi(audience: Audience) {
  const path = base(audience);
  return {
    get: (companyId: number) => apiClient.get<{ data: EmployeeAppSettings }>(path, undefined, { companyId }),
    updateBranding: (companyId: number, branding: BrandingUpdate) =>
      apiClient.patch<{ data: EmployeeAppSettings }>(`${path}/branding`, { branding }, { companyId }),
    updateHelpContacts: (companyId: number, helpContacts: HelpContact[]) =>
      apiClient.put<{ data: EmployeeAppSettings }>(`${path}/help_contacts`, { help_contacts: helpContacts }, { companyId }),
    uploadLogo: (companyId: number, file: File) => {
      const form = new FormData();
      form.append('file', file);
      return apiClient.postForm<{ data: EmployeeAppSettings }>(`${path}/logo`, form, { companyId });
    },
    removeLogo: (companyId: number) => apiClient.delete<{ data: EmployeeAppSettings }>(`${path}/logo`, { companyId }),
    // The company is explicit so a switch while the preview loads can't show
    // another client's logo.
    logo: async (companyId: number) => (await apiClient.getBlobWithParams(`${path}/logo`, undefined, { companyId, notifyMaintenance: false })).blob,
  };
}
