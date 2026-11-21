// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Invoice, InvoiceBillingProfile, InvoiceRecipient } from '@/services/api';
import { InvoiceMaker } from './InvoiceMaker';

const api = vi.hoisted(() => ({
  invoices: { list: vi.fn(), get: vi.fn(), updateEmail: vi.fn() },
  recipients: { list: vi.fn() },
  profiles: { list: vi.fn() },
  chats: { list: vi.fn() },
}));

vi.mock('@/services/api', () => ({
  invoicesApi: api.invoices,
  invoiceRecipientsApi: api.recipients,
  invoiceBillingProfilesApi: api.profiles,
  invoiceChatSessionsApi: api.chats,
}));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1, activeCompany: { id: 1, name: 'Cornerstone', organization_id: 1 }, activeOrganizationId: 1, companies: [] }),
}));
vi.mock('@/contexts/FinanceBookContext', () => ({ FinanceBookSelector: () => null }));

const SUBJECT = "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026";
const BODY = 'Hello,\n\nPlease find attached invoice 07052 for November 2026. The amount due is $300.00, due by December 15, 2026.\n\nThank you for your business.\nCornerstone Payroll LLC';

const profile = {
  id: 2, organization_id: 1, name: 'Cornerstone', legal_name: 'Cornerstone Payroll LLC', active: true, is_default: true, email: 'billing@cornerstone.example',
  numbering_style: 'continuing', next_invoice_number: 7055, invoice_number_width: 5, next_invoice_number_preview: '07055',
  service_catalog: [{ name: 'Monthly payroll processing', description_template: 'Payroll processing and filings for {month}', line_kind: 'service_fee' }],
} as InvoiceBillingProfile;
const recipient = { id: 3, name: "MoSa's Hot Box, Inc.", email: 'billing@mosas.example', payment_terms: 'Net 15', active: true } as InvoiceRecipient;

function issuedInvoice(overrides: Partial<Invoice> = {}): Invoice {
  return {
    id: 7, organization_id: 1, invoice_recipient_id: 3, invoice_billing_profile_id: 2, recipient_name: recipient.name, billing_profile_name: 'Cornerstone',
    invoice_number: '07052', invoice_date: '2026-11-30', due_date: '2026-12-15', currency: 'USD', origin: 'native',
    service_period_start: '2026-11-01', service_period_end: '2026-11-30', discount_type: 'none', discount_value: 0, subtotal_amount: 300,
    discount_amount: 0, total_amount: 300, amount_paid: 0, credit_total: 0, balance_due: 300, status: 'open', base_status: 'open',
    archived: false, payment_terms: 'Net 15', line_item_count: 1, line_items: [],
    // 8 PM UTC on Nov 29 is Nov 30 in Guam.
    generated_at: '2026-11-29T20:00:00Z', created_at: '2026-11-29T20:00:00Z', updated_at: '2026-11-29T20:00:00Z',
    invoice_recipient: recipient, invoice_billing_profile: profile,
    email: { subject: SUBJECT, body: BODY, default_subject: SUBJECT, default_body: BODY, subject_customized: false, body_customized: false },
    ...overrides,
  } as Invoice;
}

function renderPage() {
  return render(<MemoryRouter initialEntries={['/tools/invoices/assistant']}><InvoiceMaker /></MemoryRouter>);
}

describe('InvoiceMaker', () => {
  beforeEach(() => {
    Object.values(api).forEach((group) => Object.values(group).forEach((mock) => mock.mockReset()));
    api.invoices.list.mockResolvedValue({ invoices: [issuedInvoice()] });
    api.invoices.get.mockResolvedValue({ invoice: issuedInvoice() });
    api.recipients.list.mockResolvedValue({ invoice_recipients: [recipient] });
    api.profiles.list.mockResolvedValue({ invoice_billing_profiles: [profile] });
    api.chats.list.mockResolvedValue({ invoice_chat_sessions: [] });
  });

  afterEach(() => cleanup());

  it('dates the issued invoice by the Guam calendar', async () => {
    renderPage();
    expect(await screen.findByText(/Issued Nov 30, 2026/)).toBeTruthy();
  });

  it("fills an issued invoice's Email Draft and saves edits without reissuing", async () => {
    const user = userEvent.setup();
    api.invoices.updateEmail.mockResolvedValue({ invoice: issuedInvoice({
      email: { subject: 'Invoice 07052 - November', body: BODY, default_subject: SUBJECT, default_body: BODY, subject_customized: true, body_customized: false },
    }) });
    renderPage();

    await user.click(await screen.findByText('07052'));
    const subject = await screen.findByRole('textbox', { name: 'Subject' });
    await waitFor(() => expect(subject).toHaveProperty('value', SUBJECT));
    expect(screen.getByRole('textbox', { name: 'Message' })).toHaveProperty('value', BODY);
    expect((subject as HTMLInputElement).disabled).toBe(false);

    await user.clear(subject);
    await user.type(subject, 'Invoice 07052 - November');
    await user.click(screen.getByRole('button', { name: 'Save email' }));

    await waitFor(() => expect(api.invoices.updateEmail).toHaveBeenCalledWith(7, { email_subject: 'Invoice 07052 - November', email_body: '' }));
    expect(await screen.findByText(/^Edited email/)).toBeTruthy();
  });

  it('shows the default email for a new draft from the chosen sender and customer', async () => {
    renderPage();
    await screen.findByText('07052');

    const subject = screen.getByRole('textbox', { name: 'Subject' });
    expect((subject as HTMLInputElement).value).toMatch(/^Invoice 07055 - /);
  });

  it('labels every sender field and stacks each saved service', async () => {
    const user = userEvent.setup();
    renderPage();

    const card = (await screen.findByRole('heading', { name: 'Billing Profiles' })).closest('[id="billing-profiles"]') as HTMLElement;
    await user.click(await within(card).findByRole('button', { name: /^Cornerstone/ }));

    for (const label of ['Profile name', 'Legal or display name', 'Phone', 'Email', 'Website', 'Remittance address', 'Payment instructions',
      'Invoice prefix', 'Checks payable to', 'Default payment terms', 'Footer note']) {
      expect(within(card).getByLabelText(label), label).toBeTruthy();
    }
    expect(within(card).getByLabelText('Profile name')).toHaveProperty('value', 'Cornerstone');
    const services = within(card).getByRole('group', { name: 'Saved services' });
    expect(within(services).getByLabelText('Service 1 name')).toHaveProperty('value', 'Monthly payroll processing');
    expect(within(services).getByLabelText('Description')).toHaveProperty('value', 'Payroll processing and filings for {month}');
    expect(within(services).getByLabelText('Kind')).toHaveProperty('value', 'service_fee');
    expect(within(services).getByRole('button', { name: 'Remove service 1' })).toBeTruthy();
  });

  describe('an unsaved edit to an issued invoice email', () => {
    const SECOND_SUBJECT = "Invoice 07053 - MoSa's Hot Box, Inc. - December 2026";
    const second = () => issuedInvoice({
      id: 8, invoice_number: '07053',
      email: { subject: SECOND_SUBJECT, body: BODY, default_subject: SECOND_SUBJECT, default_body: BODY, subject_customized: false, body_customized: false },
    });

    beforeEach(() => {
      api.invoices.list.mockResolvedValue({ invoices: [issuedInvoice(), second()] });
      api.invoices.get.mockImplementation(async (id: number) => ({ invoice: id === 8 ? second() : issuedInvoice() }));
    });

    afterEach(() => vi.restoreAllMocks());

    async function editFirstInvoiceSubject() {
      const user = userEvent.setup();
      renderPage();
      await user.click(await screen.findByText('07052'));
      const subject = await screen.findByRole('textbox', { name: 'Subject' });
      await waitFor(() => expect(subject).toHaveProperty('value', SUBJECT));
      await user.clear(subject);
      await user.type(subject, 'Unsaved subject');
      return { user, subject };
    }

    it('asks before switching to another invoice and keeps the edit when cancelled', async () => {
      const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
      const { user, subject } = await editFirstInvoiceSubject();

      await user.click(screen.getByText('07053'));

      expect(confirm).toHaveBeenCalledWith('Discard unsaved invoice changes?');
      expect(api.invoices.get).not.toHaveBeenCalledWith(8);
      expect(subject).toHaveProperty('value', 'Unsaved subject');
    });

    it('asks before starting a new invoice', async () => {
      const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
      const { user, subject } = await editFirstInvoiceSubject();

      await user.click(screen.getByRole('button', { name: 'New' }));

      expect(confirm).toHaveBeenCalledWith('Discard unsaved invoice changes?');
      expect(subject).toHaveProperty('value', 'Unsaved subject');
    });

    it("doesn't let a late save replace the next invoice's email", async () => {
      vi.spyOn(window, 'confirm').mockReturnValue(true);
      let finishSave: (value: { invoice: Invoice }) => void = () => {};
      api.invoices.updateEmail.mockReturnValue(new Promise((resolve) => { finishSave = resolve; }));
      const { user } = await editFirstInvoiceSubject();

      await user.click(screen.getByRole('button', { name: 'Save email' }));
      await user.click(screen.getByText('07053'));
      const subject = screen.getByRole('textbox', { name: 'Subject' });
      await waitFor(() => expect(subject).toHaveProperty('value', SECOND_SUBJECT));

      finishSave({ invoice: issuedInvoice({
        email: { subject: 'Unsaved subject', body: BODY, default_subject: SUBJECT, default_body: BODY, subject_customized: true, body_customized: false },
      }) });
      await waitFor(() => expect(api.invoices.updateEmail).toHaveBeenCalledWith(7, { email_subject: 'Unsaved subject', email_body: '' }));
      await new Promise((resolve) => setTimeout(resolve, 0));

      expect(subject).toHaveProperty('value', SECOND_SUBJECT);
      expect((subject as HTMLInputElement).disabled).toBe(false);
      expect(screen.queryByText('Email saved. The issued PDF is unchanged.')).toBeNull();
    });

    it('locks the email fields while the save is in flight', async () => {
      let finishSave: (value: { invoice: Invoice }) => void = () => {};
      api.invoices.updateEmail.mockReturnValue(new Promise((resolve) => { finishSave = resolve; }));
      const { user, subject } = await editFirstInvoiceSubject();

      await user.click(screen.getByRole('button', { name: 'Save email' }));

      expect((subject as HTMLInputElement).disabled).toBe(true);
      expect((screen.getByRole('textbox', { name: 'Message' }) as HTMLTextAreaElement).disabled).toBe(true);
      finishSave({ invoice: issuedInvoice({
        email: { subject: 'Unsaved subject', body: BODY, default_subject: SUBJECT, default_body: BODY, subject_customized: true, body_customized: false },
      }) });
      expect(await screen.findByText('Email saved. The issued PDF is unchanged.')).toBeTruthy();
      expect((subject as HTMLInputElement).disabled).toBe(false);
      expect(subject).toHaveProperty('value', 'Unsaved subject');
    });
  });

  it.each([
    ['Subject', { email_subject: '', email_body: 'Custom message' }],
    ['Message', { email_subject: 'Custom subject', email_body: '' }],
  ])("clearing only an issued invoice's %s restores just that default", async (field, expected) => {
    const custom = { subject: 'Custom subject', body: 'Custom message', default_subject: SUBJECT, default_body: BODY, subject_customized: true, body_customized: true };
    api.invoices.get.mockResolvedValue({ invoice: issuedInvoice({ email: custom }) });
    api.invoices.updateEmail.mockResolvedValue({ invoice: issuedInvoice() });
    const user = userEvent.setup();
    renderPage();
    await user.click(await screen.findByText('07052'));
    const input = await screen.findByRole('textbox', { name: field });
    await waitFor(() => expect(input).toHaveProperty('value', field === 'Subject' ? 'Custom subject' : 'Custom message'));

    await user.clear(input);
    await user.click(screen.getByRole('button', { name: 'Save email' }));

    await waitFor(() => expect(api.invoices.updateEmail).toHaveBeenCalledWith(7, expected));
  });
});
