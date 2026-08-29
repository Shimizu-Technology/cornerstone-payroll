import {
  Bell,
  Building2,
  CalendarClock,
  ClipboardList,
  FileSpreadsheet,
  Gauge,
  Landmark,
  Link2,
  ListPlus,
  Printer,
  ShieldCheck,
  SlidersHorizontal,
  UserCog,
} from 'lucide-react';
import type { ReactNode } from 'react';
import type { StaffCapability } from '@/contexts/AuthContext';

export interface SettingsNavigationItem {
  label: string;
  description: string;
  href: string;
  icon: ReactNode;
  capability?: StaffCapability;
  keywords: string[];
}

const iconClass = 'h-[18px] w-[18px] shrink-0';

export const clientSettingsNavigation: SettingsNavigationItem[] = [
  {
    label: 'Overview',
    description: 'Review configuration readiness for the active client.',
    href: '/client-settings/overview',
    icon: <Gauge className={iconClass} />,
    keywords: ['settings', 'readiness', 'setup', 'client'],
  },
  {
    label: 'Company profile',
    description: 'Maintain employer identity, contact information, and mailing address.',
    href: '/client-settings/company',
    icon: <Building2 className={iconClass} />,
    keywords: ['company', 'client', 'ein', 'address', 'contact'],
  },
  {
    label: 'Payroll schedule',
    description: 'Confirm payroll cadence and the legal overtime workweek.',
    href: '/client-settings/payroll',
    icon: <CalendarClock className={iconClass} />,
    capability: 'manage_client_configuration',
    keywords: ['pay schedule', 'workweek', 'frequency', 'pay date'],
  },
  {
    label: 'Earnings & deductions',
    description: 'Configure additions, deductions, and employer contributions.',
    href: '/client-settings/pay-items',
    icon: <ListPlus className={iconClass} />,
    capability: 'manage_client_configuration',
    keywords: ['payroll fields', 'earnings', 'deductions', 'contributions'],
  },
  {
    label: 'Checks & printing',
    description: 'Control client check stock, layout, automation, and numbering.',
    href: '/client-settings/checks',
    icon: <Printer className={iconClass} />,
    capability: 'manage_client_configuration',
    keywords: ['checks', 'stock', 'layout', 'numbering'],
  },
  {
    label: 'Reports & exports',
    description: 'Choose client-specific payroll register and export behavior.',
    href: '/client-settings/reports',
    icon: <FileSpreadsheet className={iconClass} />,
    capability: 'manage_client_configuration',
    keywords: ['reports', 'exports', 'register', 'excel'],
  },
  {
    label: 'Notifications',
    description: 'Configure payroll reminder recipients and timing.',
    href: '/client-settings/notifications',
    icon: <Bell className={iconClass} />,
    capability: 'manage_client_configuration',
    keywords: ['reminders', 'notifications', 'email'],
  },
  {
    label: 'Time tracking',
    description: 'Connect and verify the client’s external time source.',
    href: '/client-settings/integrations',
    icon: <Link2 className={iconClass} />,
    capability: 'manage_organization',
    keywords: ['time tracking', 'integration', 'source', 'credentials'],
  },
];

export const firmSettingsNavigation: SettingsNavigationItem[] = [
  {
    label: 'Team & access',
    description: 'Invite users and manage firm and client access.',
    href: '/firm-settings/team',
    icon: <UserCog className={iconClass} />,
    capability: 'manage_organization',
    keywords: ['users', 'team', 'permissions', 'invites'],
  },
  {
    label: 'Printer profiles',
    description: 'Maintain reusable office-printer calibration profiles.',
    href: '/firm-settings/printers',
    icon: <Printer className={iconClass} />,
    capability: 'manage_organization',
    keywords: ['printer', 'profiles', 'calibration', 'firm'],
  },
];

export const platformAdminNavigation: SettingsNavigationItem[] = [
  {
    label: 'Organizations',
    description: 'Provision and manage payroll organizations.',
    href: '/platform/organizations',
    icon: <Landmark className={iconClass} />,
    capability: 'manage_platform',
    keywords: ['organizations', 'tenants', 'platform'],
  },
  {
    label: 'System tax rules',
    description: 'Maintain annual tax rules used across the platform.',
    href: '/platform/tax-rules',
    icon: <SlidersHorizontal className={iconClass} />,
    capability: 'manage_platform',
    keywords: ['tax', 'rates', 'brackets', 'platform'],
  },
];

export const administrationNavigation = {
  clients: {
    label: 'Client Management',
    description: 'Create clients and manage their operational status.',
    href: '/settings/clients',
    icon: <Building2 className={iconClass} />,
    keywords: ['clients', 'companies'],
  },
  audit: {
    label: 'Audit History',
    description: 'Review firm activity and security events.',
    href: '/settings/audit-logs',
    icon: <ClipboardList className={iconClass} />,
    keywords: ['audit', 'history', 'security'],
  },
  clientPortal: {
    label: 'Client Portal',
    description: 'Manage client documents and requested changes.',
    href: '/settings/client-documents',
    icon: <ShieldCheck className={iconClass} />,
    keywords: ['client portal', 'documents', 'changes'],
  },
};
