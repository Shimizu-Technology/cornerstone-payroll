import { apiClient } from '@/services/api';

export type NotificationDeliveryMode = 'immediate' | 'digest' | 'off';

export interface NotificationCategory {
  key: string;
  label: string;
  description: string;
  delivery_mode: NotificationDeliveryMode;
  default_mode: Exclude<NotificationDeliveryMode, 'off'>;
}

export interface RecentPortalAlert {
  id: number;
  category: string;
  label: string;
  company_name: string | null;
  status: 'pending' | 'sent' | 'failed' | 'skipped';
  delivery_mode: 'immediate' | 'digest';
  skip_reason: string | null;
  occurred_at: string;
  deliver_after: string;
  sent_at: string | null;
  attempts: number;
}

export interface ClientWithoutRecipients {
  company_id: number;
  company_name: string | null;
  event_count: number;
  last_occurred_at: string;
}

export interface NotificationSettings {
  email_delivery_enabled: boolean;
  digest_time_label: string;
  categories: NotificationCategory[];
  recent_alerts: RecentPortalAlert[];
  administration?: { clients_without_recipients: ClientWithoutRecipients[] };
}

export interface PortalAlertRecipients {
  company_id: number;
  eligible_users: { id: number; name: string; email: string; role: string; selected: boolean }[];
  ineligible_listed_users: { id: number; name: string }[];
  extra_emails: string[];
  recipient_count: number;
  max_extra_emails: number;
  unnotified_event_count: number;
  email_delivery_enabled: boolean;
}

export const notificationSettingsApi = {
  get: (): Promise<{ data: NotificationSettings }> => apiClient.get<{ data: NotificationSettings }>('/notification_settings'),
  update: (preferences: Record<string, NotificationDeliveryMode>): Promise<{ data: NotificationSettings }> =>
    apiClient.patch<{ data: NotificationSettings }>('/notification_settings', { preferences }),
};

export const portalAlertRecipientsApi = {
  get: (companyId: number): Promise<{ data: PortalAlertRecipients }> =>
    apiClient.get<{ data: PortalAlertRecipients }>('/admin/portal_notification_recipients', undefined, { companyId }),
  update: (companyId: number, payload: { user_ids: number[]; emails: string[] }): Promise<{ data: PortalAlertRecipients }> =>
    apiClient.put<{ data: PortalAlertRecipients }>('/admin/portal_notification_recipients', payload, { companyId }),
};
