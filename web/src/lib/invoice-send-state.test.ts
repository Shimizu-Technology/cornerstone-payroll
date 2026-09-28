import { describe, expect, it } from 'vitest';
import { invoiceSendState } from './invoice-send-state';

describe('invoiceSendState', () => {
  const invoice = { id: 1, sent_at: null };

  it('uses the latest non-cancelled send attempt instead of a historical failure', () => {
    expect(invoiceSendState(invoice, [
      { id: 1, invoice_id: 1, status: 'failed' },
      { id: 2, invoice_id: 1, status: 'sent' },
    ])).toBe('provider_accepted');
    expect(invoiceSendState(invoice, [
      { id: 3, invoice_id: 1, status: 'cancelled' },
      { id: 2, invoice_id: 1, status: 'pending' },
    ])).toBe('scheduled');
  });

  it('keeps recorded delivery separate from provider acceptance', () => {
    expect(invoiceSendState({ id: 1, sent_at: '2026-09-29T00:00:00Z' }, [])).toBe('recorded_delivery');
    expect(invoiceSendState(invoice, [])).toBe('not_sent');
  });
});
