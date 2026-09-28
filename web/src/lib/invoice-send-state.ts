import type { Invoice, InvoiceSendSchedule } from '@/services/api';

export type SendState = 'not_sent' | 'scheduled' | 'failed' | 'provider_accepted' | 'recorded_delivery';

export function invoiceSendState(
  invoice: Pick<Invoice, 'id' | 'sent_at'>,
  schedules: Array<Pick<InvoiceSendSchedule, 'id' | 'invoice_id' | 'status'>>,
): SendState {
  const latest = schedules.filter((schedule) => schedule.invoice_id === invoice.id && schedule.status !== 'cancelled')
    .reduce<(typeof schedules)[number] | null>((current, schedule) => !current || schedule.id > current.id ? schedule : current, null);
  if (latest?.status === 'failed') return 'failed';
  if (latest && ['pending', 'queued', 'sending'].includes(latest.status)) return 'scheduled';
  if (latest?.status === 'sent') return 'provider_accepted';
  return invoice.sent_at ? 'recorded_delivery' : 'not_sent';
}
