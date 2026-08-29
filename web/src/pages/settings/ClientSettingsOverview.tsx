import { useCallback, useEffect, useRef, useState, type ReactElement, type ReactNode } from 'react';
import { AlertTriangle, Bell, Building2, CalendarClock, CheckCircle2, Clock3, FileSpreadsheet, Link2, ListPlus, Printer } from 'lucide-react';
import { Link } from 'react-router';
import { SettingsSection } from '@/components/settings/SettingsSection';
import { Card, CardContent } from '@/components/ui/card';
import { useCompany } from '@/contexts/CompanyContext';
import { useAuth, type StaffCapability } from '@/contexts/AuthContext';
import {
  checksApi,
  companiesApi,
  payScheduleSettingsApi,
  payrollFieldsApi,
  payrollReminderApi,
  timeTrackingSourcesApi,
} from '@/services/api';

type ReadinessTone = 'ready' | 'attention' | 'optional' | 'unknown';

interface ReadinessItem {
  label: string;
  detail: string;
  href: string;
  tone: ReadinessTone;
  icon: ReactNode;
  capability?: StaffCapability;
}

const iconClass = 'h-5 w-5';

export function ClientSettingsOverview(): ReactElement {
  const { can } = useAuth();
  const { activeCompany, activeCompanyId } = useCompany();
  const [items, setItems] = useState<ReadinessItem[]>([]);
  const [loading, setLoading] = useState(true);
  const requestIdRef = useRef(0);
  const activeCompanyIdRef = useRef(activeCompanyId);
  activeCompanyIdRef.current = activeCompanyId;

  const load = useCallback(async () => {
    const requestId = ++requestIdRef.current;
    const requestedCompanyId = activeCompanyId;
    if (!activeCompanyId) {
      setItems([]);
      setLoading(false);
      return;
    }
    setLoading(true);

    const [companyResult, scheduleResult, fieldsResult, checksResult, remindersResult, sourcesResult] = await Promise.allSettled([
      companiesApi.get(activeCompanyId),
      payScheduleSettingsApi.get(),
      payrollFieldsApi.list({ active: true }),
      checksApi.getSettings(),
      payrollReminderApi.getConfig(),
      timeTrackingSourcesApi.list(),
    ]);
    if (requestId !== requestIdRef.current || requestedCompanyId !== activeCompanyIdRef.current) return;

    const company = companyResult.status === 'fulfilled' ? companyResult.value.company : null;
    const schedule = scheduleResult.status === 'fulfilled' ? scheduleResult.value.pay_schedule_settings : null;
    const fields = fieldsResult.status === 'fulfilled' ? fieldsResult.value.payroll_fields : null;
    const checkSettings = checksResult.status === 'fulfilled' ? checksResult.value.check_settings : null;
    const reminders = remindersResult.status === 'fulfilled' ? remindersResult.value.payroll_reminder_config : null;
    const sources = sourcesResult.status === 'fulfilled' ? sourcesResult.value.time_tracking_sources : null;
    const scheduleConfirmed = schedule?.pay_schedule.confirmation_status === 'confirmed';
    const workweekConfirmed = schedule?.workweek.confirmation_status === 'confirmed';

    const readinessItems: ReadinessItem[] = [
      {
        label: 'Company profile',
        detail: company?.ein && company?.address_line1 ? 'Employer identity and address are on file.' : 'Review the employer identity, EIN, and contact information.',
        href: '/client-settings/company',
        tone: company ? (company.ein && company.address_line1 ? 'ready' : 'attention') : 'unknown',
        icon: <Building2 className={iconClass} />,
      },
      {
        label: 'Payroll schedule',
        detail: scheduleConfirmed && workweekConfirmed
          ? 'Payroll cadence and legal overtime workweek are employer-confirmed.'
          : 'Employer confirmation is required before overtime-sensitive imports and calculations.',
        href: '/client-settings/payroll',
        tone: schedule ? (scheduleConfirmed && workweekConfirmed ? 'ready' : 'attention') : 'unknown',
        icon: <CalendarClock className={iconClass} />,
        capability: 'manage_client_configuration',
      },
      {
        label: 'Earnings & deductions',
        detail: fields ? `${fields.length} active reusable pay item${fields.length === 1 ? '' : 's'} configured.` : 'Could not verify reusable pay items.',
        href: '/client-settings/pay-items',
        tone: fields ? (fields.length > 0 ? 'ready' : 'optional') : 'unknown',
        icon: <ListPlus className={iconClass} />,
        capability: 'manage_client_configuration',
      },
      {
        label: 'Checks & printing',
        detail: checkSettings ? `Next check number: ${checkSettings.next_check_number}. Stock: ${checkSettings.check_stock_type.replaceAll('_', ' ')}.` : 'Could not verify check configuration.',
        href: '/client-settings/checks',
        tone: checkSettings ? 'ready' : 'unknown',
        icon: <Printer className={iconClass} />,
        capability: 'manage_client_configuration',
      },
      {
        label: 'Reports & exports',
        detail: company?.simple_payroll_register_enabled ? 'The client-specific simple payroll register is enabled.' : 'Standard detailed payroll exports are enabled.',
        href: '/client-settings/reports',
        tone: company ? 'ready' : 'unknown',
        icon: <FileSpreadsheet className={iconClass} />,
        capability: 'manage_client_configuration',
      },
      {
        label: 'Notifications',
        detail: reminders?.enabled ? `Payroll reminders are enabled for ${reminders.recipients.length} recipient${reminders.recipients.length === 1 ? '' : 's'}.` : 'Payroll reminders are currently disabled.',
        href: '/client-settings/notifications',
        tone: reminders ? (reminders.enabled ? 'ready' : 'optional') : 'unknown',
        icon: <Bell className={iconClass} />,
        capability: 'manage_client_configuration',
      },
      {
        label: 'Time tracking',
        detail: sources?.some((source) => source.active) ? 'An active time-tracking source is connected.' : 'No active external time-tracking source is configured.',
        href: '/client-settings/integrations',
        tone: sources ? (sources.some((source) => source.active) ? 'ready' : 'optional') : 'unknown',
        icon: <Link2 className={iconClass} />,
        capability: 'manage_organization',
      },
    ];
    setItems(readinessItems.filter((item) => !item.capability || can(item.capability)));
    setLoading(false);
  }, [activeCompanyId, can]);

  useEffect(() => { void load(); }, [load]);

  if (loading) {
    return <div className="rounded-[1.35rem] border border-neutral-200 bg-white p-10 text-center text-sm text-neutral-500">Reviewing client configuration…</div>;
  }

  if (!activeCompanyId) {
    return <div className="rounded-[1.35rem] border border-warning-200 bg-warning-50 p-10 text-center text-sm text-warning-900">Select a client to review its configuration.</div>;
  }

  const attentionCount = items.filter((item) => item.tone === 'attention').length;

  return (
    <SettingsSection
      title="Configuration overview"
      description={`A single readiness view for ${activeCompany?.name || 'the active client'}. Required payroll controls stay separate from optional conveniences.`}
    >
      <Card className={attentionCount > 0 ? 'border-warning-200 bg-warning-50/35' : 'border-success-200 bg-success-50/30'}>
        <CardContent className="flex items-start gap-3 py-5">
          {attentionCount > 0
            ? <AlertTriangle className="mt-0.5 h-5 w-5 text-warning-700" />
            : <CheckCircle2 className="mt-0.5 h-5 w-5 text-success-700" />}
          <div>
            <p className="font-semibold text-neutral-950">{attentionCount > 0 ? `${attentionCount} required item${attentionCount === 1 ? '' : 's'} need attention` : 'Required payroll configuration is ready'}</p>
            <p className="mt-1 text-sm leading-6 text-neutral-600">Optional settings can remain off without blocking payroll. Open any row below to review its source and impact.</p>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 xl:grid-cols-2">
        {items.map((item) => {
          const toneClasses = {
            ready: 'border-success-200 bg-success-50/20 text-success-700',
            attention: 'border-warning-200 bg-warning-50/30 text-warning-700',
            optional: 'border-neutral-200 bg-white text-neutral-500',
            unknown: 'border-danger-200 bg-danger-50/20 text-danger-700',
          }[item.tone];
          const statusLabel = { ready: 'Ready', attention: 'Needs attention', optional: 'Optional', unknown: 'Unavailable' }[item.tone];

          return (
            <Link key={item.href} to={item.href} className="group rounded-[1.2rem] border border-neutral-200 bg-white p-4 shadow-[0_16px_36px_-32px_rgba(15,23,42,0.55)] transition duration-150 hover:-translate-y-0.5 hover:border-primary-200 hover:shadow-[0_18px_42px_-28px_rgba(30,64,175,0.28)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
              <div className="flex items-start gap-4">
                <div className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl border ${toneClasses}`}>{item.icon}</div>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <h3 className="font-semibold text-neutral-950 group-hover:text-primary-800">{item.label}</h3>
                    <span className={`rounded-full border px-2.5 py-1 text-[11px] font-bold uppercase tracking-[0.1em] ${toneClasses}`}>{statusLabel}</span>
                  </div>
                  <p className="mt-2 text-sm leading-6 text-neutral-500">{item.detail}</p>
                </div>
              </div>
            </Link>
          );
        })}
      </div>

      <div className="flex items-start gap-3 rounded-2xl border border-neutral-200 bg-white px-4 py-3 text-sm text-neutral-600">
        <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" />
        <p>Effective-dated payroll settings preserve completed payroll. A settings move never recalculates historical runs automatically.</p>
      </div>
    </SettingsSection>
  );
}
