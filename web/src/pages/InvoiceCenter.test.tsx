// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Invoice, InvoiceBillingProfile } from '@/services/api';
import { InvoiceCenter } from './InvoiceCenter';

const api = vi.hoisted(() => ({
  invoices: { list: vi.fn(), get: vi.fn(), updateEmail: vi.fn() },
  recipients: { list: vi.fn() },
  profiles: { list: vi.fn() },
  receivables: { summary: vi.fn() },
  recurrences: { list: vi.fn(), create: vi.fn(), update: vi.fn() },
  sendSchedules: { list: vi.fn(), create: vi.fn(), update: vi.fn() },
}));

vi.mock('@/services/api', () => ({
  invoicesApi: api.invoices,
  invoiceRecipientsApi: api.recipients,
  invoiceBillingProfilesApi: api.profiles,
  invoiceReceivablesApi: api.receivables,
  invoiceRecurrencesApi: api.recurrences,
  invoiceSendSchedulesApi: api.sendSchedules,
  organizationsApi: { get: vi.fn() },
}));
vi.mock('@/components/layout/Header', () => ({
  Header: ({ title, actions }: { title: string; actions?: ReactNode }) => <div><h1>{title}</h1>{actions}</div>,
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1, organization_id: 1, role: 'admin', organization_name: 'Cornerstone' } }) }));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompany: { id: 1, name: 'Cornerstone', organization_id: 1 }, activeOrganizationId: 1, activeOrganizationName: 'Cornerstone', companies: [] }),
}));
vi.mock('@/contexts/FinanceBookContext', () => ({
  useFinanceBook: () => ({ activeBook: { id: 1, name: 'Cornerstone' } }),
  FinanceBookSelector: () => null,
}));

const SUBJECT = "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026";
const BODY = 'Hello,\n\nPlease find attached invoice 07052 for November 2026. The amount due is $300.00, due by December 15, 2026.\n\nThank you for your business.\nCornerstone Payroll LLC';

const profile: InvoiceBillingProfile = {
  id: 2, organization_id: 1, name: 'Cornerstone', active: true, is_default: true,
  numbering_style: 'continuing', next_invoice_number: 7055, invoice_number_width: 5, next_invoice_number_preview: '07055', service_catalog: [],
} as InvoiceBillingProfile;

function issuedInvoice(overrides: Partial<Invoice> = {}): Invoice {
  return {
    id: 7, organization_id: 1, invoice_recipient_id: 3, invoice_billing_profile_id: 2, recipient_name: "MoSa's Hot Box, Inc.",
    billing_profile_name: 'Cornerstone', invoice_number: '07052', invoice_date: '2026-11-30', due_date: '2026-12-15', currency: 'USD',
    origin: 'native', service_period_start: '2026-11-01', service_period_end: '2026-11-30', discount_type: 'none', discount_value: 0,
    subtotal_amount: 300, discount_amount: 0, total_amount: 300, amount_paid: 0, credit_total: 0, balance_due: 300, status: 'open',
    base_status: 'open', archived: false, payment_terms: 'Net 15', line_item_count: 1, has_artifact: true,
    created_at: '2026-11-30T00:00:00Z', updated_at: '2026-11-30T00:00:00Z',
    artifacts: [{ id: 1, kind: 'issued_pdf', filename: '07052.pdf', content_type: 'application/pdf', byte_size: 10, sha256: 'abc', created_at: '2026-11-30T00:00:00Z' }],
    payments: [], credit_notes: [], events: [],
    deliveries: [{ id: 11, channel: 'email', recipient: 'billing@mosas.example', delivered_at: '2026-11-30T01:00:00Z', created_at: '2026-11-30T01:00:00Z',
      email_subject: 'Invoice 07052 (first send)', email_body: 'Hi Mo, attached.', correctable: false }],
    invoice_recipient: { id: 3, name: "MoSa's Hot Box, Inc.", email: 'billing@mosas.example', payment_terms: 'Net 15' },
    email: { subject: SUBJECT, body: BODY, default_subject: SUBJECT, default_body: BODY, subject_customized: false, body_customized: false },
    recurring_terms: { payment_terms: 'Net 15', due_after_days: 15 },
    ...overrides,
  } as Invoice;
}

async function openInvoice() {
  const user = userEvent.setup();
  render(<MemoryRouter><InvoiceCenter /></MemoryRouter>);
  await user.click(await screen.findByRole('button', { name: /07052/ }));
  const dialog = await screen.findByRole('dialog', { name: /07052/ });
  return { user, dialog };
}

describe('InvoiceCenter', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'], shouldAdvanceTime: true });
    vi.setSystemTime(new Date('2026-11-21T02:00:00Z'));
    Object.values(api).forEach((group) => Object.values(group).forEach((mock) => mock.mockReset()));
    api.invoices.list.mockResolvedValue({ invoices: [issuedInvoice()] });
    api.invoices.get.mockResolvedValue({ invoice: issuedInvoice() });
    api.recipients.list.mockResolvedValue({ invoice_recipients: [] });
    api.profiles.list.mockResolvedValue({ invoice_billing_profiles: [profile] });
    api.receivables.summary.mockResolvedValue({ as_of: '2026-11-21', totals: {}, aging: {}, by_recipient: [] });
    api.recurrences.list.mockResolvedValue({ invoice_recurrences: [] });
    api.sendSchedules.list.mockResolvedValue({ invoice_send_schedules: [] });
    api.sendSchedules.create.mockResolvedValue({ invoice_send_schedule: {} });
    api.recurrences.create.mockResolvedValue({ invoice_recurrence: {} });
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('prefills the send panel with the default email and sends the edited subject', async () => {
    const { user, dialog } = await openInvoice();

    await user.click(within(dialog).getByRole('button', { name: 'Send now' }));
    const subject = within(dialog).getByRole('textbox', { name: 'Subject' });
    expect(subject).toHaveProperty('value', SUBJECT);
    expect(within(dialog).getByRole('textbox', { name: 'Message' })).toHaveProperty('value', BODY);

    await user.clear(subject);
    await user.type(subject, 'Invoice 07052 - November 2026 (corrected)');
    await user.click(within(dialog).getByRole('button', { name: 'Confirm and send' }));

    await waitFor(() => expect(api.sendSchedules.create).toHaveBeenCalledWith({
      invoice_id: 7, recipients: ['billing@mosas.example'], send_now: true, subject: 'Invoice 07052 - November 2026 (corrected)', body: BODY,
    }));
  });

  it('edits an issued invoice email and shows what each send said', async () => {
    api.invoices.updateEmail.mockResolvedValue({ invoice: issuedInvoice() });
    const { user, dialog } = await openInvoice();

    const history = within(dialog).getByText('Delivery history').closest('div')!.parentElement!;
    expect(within(history).getByText('Subject: Invoice 07052 (first send)')).toBeTruthy();

    const card = within(dialog).getByRole('region', { name: 'Email message' });
    expect(within(card).getByText(SUBJECT)).toBeTruthy();
    await user.click(within(card).getByRole('button', { name: 'Edit email' }));
    const message = within(card).getByRole('textbox', { name: 'Message' });
    await user.clear(message);
    await user.type(message, 'Hi Mo,{enter}{enter}November is attached.');
    await user.click(within(card).getByRole('button', { name: 'Save email' }));

    // The unchanged subject is the default, so it is saved blank and keeps following the invoice.
    await waitFor(() => expect(api.invoices.updateEmail).toHaveBeenCalledWith(7, { email_subject: '', email_body: 'Hi Mo,\n\nNovember is attached.' }));
  });

  it('labels the new-invoice dialog and previews the continuing number', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><InvoiceCenter /></MemoryRouter>);
    await screen.findByRole('button', { name: /07052/ });

    await user.click(screen.getByRole('button', { name: 'New invoice' }));

    const dialog = await screen.findByRole('dialog', { name: 'New invoice' });
    expect(dialog.getAttribute('aria-modal')).toBe('true');
    expect(within(dialog).getByRole('textbox', { name: /Invoice number/ }).getAttribute('placeholder')).toBe('Next: 07055 (assigned when issued)');
  });

  it('starts a recurrence the period after the invoice and follows the customer terms', async () => {
    const { user, dialog } = await openInvoice();

    await user.click(within(dialog).getByRole('button', { name: 'Make recurring' }));
    expect(within(dialog).getByLabelText('First invoice date')).toHaveProperty('value', '2026-12-01');
    expect(within(dialog).queryByLabelText('Due after days')).toBeNull();
    expect(within(dialog).getByText('Net 15')).toBeTruthy();

    await user.selectOptions(within(dialog).getByLabelText('Repeat'), 'week');
    expect(within(dialog).getByLabelText('First invoice date')).toHaveProperty('value', '2026-11-22');
    await user.selectOptions(within(dialog).getByLabelText('Repeat'), 'month');
    await user.click(within(dialog).getByRole('button', { name: 'Create schedule' }));

    await waitFor(() => expect(api.recurrences.create).toHaveBeenCalledWith({
      source_invoice_id: 7, start_on: '2026-12-01', ends_on: null, interval_unit: 'month', interval_count: 1,
    }));
  });

  it('asks for due days, defaulted from the terms, when the sender does not follow customer terms', async () => {
    api.invoices.get.mockResolvedValue({ invoice: issuedInvoice({ recurring_terms: null }) });
    const { user, dialog } = await openInvoice();

    await user.click(within(dialog).getByRole('button', { name: 'Make recurring' }));

    expect(within(dialog).getByLabelText('Due after days')).toHaveProperty('value', '15');
  });
});
