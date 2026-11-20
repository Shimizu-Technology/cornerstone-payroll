// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { InvoiceStyleSettings } from './InvoiceStyleSettings';

const state = vi.hoisted(() => ({
  readOnly: false,
  api: { get: vi.fn(), updateStyle: vi.fn(), samplePdf: vi.fn(), uploadLogo: vi.fn(), removeLogo: vi.fn() },
}));

vi.mock('@/components/layout/Header', () => ({
  Header: ({ title, actions }: { title: string; actions?: React.ReactNode }) => <div><h1>{title}</h1>{actions}</div>,
}));
vi.mock('@/components/documents/PdfPreview', () => ({
  PdfDocumentView: ({ blob }: { blob: Blob | null }) => <div data-testid="pdf-view">{blob ? 'pdf ready' : 'no pdf'}</div>,
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 1 } }) }));
vi.mock('@/lib/company-write-access', () => ({ isTestWorkspaceCompany: () => state.readOnly }));
vi.mock('@/services/api', () => ({ invoiceBillingProfilesApi: state.api }));

const profile = {
  id: 7, organization_id: 1, name: 'Marianas Bay CPA', legal_name: 'Marianas Bay CPA', active: true, is_default: true,
  invoice_theme: 'classic', accent_color: null, effective_accent_color: '#1F4E79', logo_size: 'medium',
  show_service_period: true, show_item_column: true, show_how_to_pay: true, footer_note: 'Thank you!',
  payment_instructions: 'Make checks payable to Marianas Bay CPA.', has_logo: false,
};

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/tools/invoices/billing-profiles/7/style']}>
      <Routes><Route path="/tools/invoices/billing-profiles/:profileId/style" element={<InvoiceStyleSettings />} /></Routes>
    </MemoryRouter>,
  );
}

describe('InvoiceStyleSettings', () => {
  beforeEach(() => {
    state.readOnly = false;
    Object.values(state.api).forEach((mock) => mock.mockReset());
    state.api.get.mockResolvedValue({ invoice_billing_profile: profile });
    state.api.samplePdf.mockResolvedValue({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'sample.pdf' });
  });
  afterEach(cleanup);

  it('previews the real sample PDF with the chosen theme and color, then saves them', async () => {
    const user = userEvent.setup();
    state.api.updateStyle.mockImplementation(async (_id, style) => ({ invoice_billing_profile: { ...profile, ...style } }));
    renderPage();

    expect(await screen.findByRole('button', { name: /Classic/ })).toHaveProperty('ariaPressed', 'true');
    await waitFor(() => expect(screen.getByTestId('pdf-view').textContent).toBe('pdf ready'));
    expect(state.api.samplePdf).toHaveBeenLastCalledWith(7, expect.objectContaining({ invoice_theme: 'classic', accent_color: null }), expect.anything());

    await user.click(screen.getByRole('button', { name: /Banner/ }));
    await user.click(screen.getByRole('button', { name: 'Use color #7C2D12' }));
    await user.click(screen.getByRole('checkbox', { name: /How to pay/ }));
    await waitFor(() => expect(state.api.samplePdf).toHaveBeenLastCalledWith(
      7, expect.objectContaining({ invoice_theme: 'banner', accent_color: '#7C2D12', show_how_to_pay: false }), expect.anything(),
    ));
    expect(screen.getByText('Unsaved changes')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Save style' }));
    await waitFor(() => expect(state.api.updateStyle).toHaveBeenCalledWith(7, expect.objectContaining({
      invoice_theme: 'banner', accent_color: '#7C2D12', show_how_to_pay: false, footer_note: 'Thank you!',
    })));
    expect(await screen.findByText(/Style saved/)).toBeTruthy();
    expect(screen.queryByText('Unsaved changes')).toBeNull();
  });

  it('flags an invalid custom hex and does not preview or save it', async () => {
    const user = userEvent.setup();
    renderPage();
    const hex = await screen.findByRole('textbox', { name: 'Custom hex' });
    await waitFor(() => expect(state.api.samplePdf).toHaveBeenCalledTimes(1));

    await user.clear(hex);
    await user.type(hex, '#12');
    expect(screen.getByText('Enter six hex digits, like #1F4E79.')).toBeTruthy();
    expect(hex.getAttribute('aria-invalid')).toBe('true');
    expect((screen.getByRole('button', { name: 'Save style' }) as HTMLButtonElement).disabled).toBe(true);

    await user.type(hex, '3456');
    await waitFor(() => expect(state.api.samplePdf).toHaveBeenLastCalledWith(7, expect.objectContaining({ accent_color: '#123456' }), expect.anything()));
  });

  it('previews a chosen logo before uploading it on save', async () => {
    const user = userEvent.setup();
    URL.createObjectURL = vi.fn(() => 'blob:logo');
    URL.revokeObjectURL = vi.fn();
    state.api.updateStyle.mockResolvedValue({ invoice_billing_profile: profile });
    state.api.uploadLogo.mockResolvedValue({ invoice_billing_profile: { ...profile, has_logo: true } });
    const { container } = renderPage();
    await screen.findByText('Upload logo');

    const logo = new File(['png'], 'logo.png', { type: 'image/png' });
    await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, logo);
    await waitFor(() => expect(state.api.samplePdf).toHaveBeenLastCalledWith(7, expect.anything(), expect.objectContaining({ logo })));
    expect(screen.getByAltText('New logo, not saved yet')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Save style' }));
    await waitFor(() => expect(state.api.uploadLogo).toHaveBeenCalledWith(7, logo));
  });

  it('lets a read-only workspace preview but not save', async () => {
    state.readOnly = true;
    const user = userEvent.setup();
    renderPage();
    await user.click(await screen.findByRole('button', { name: /Modern/ }));

    expect((screen.getByRole('button', { name: 'Save style' }) as HTMLButtonElement).disabled).toBe(true);
    await waitFor(() => expect(state.api.samplePdf).toHaveBeenLastCalledWith(7, expect.objectContaining({ invoice_theme: 'modern' }), expect.anything()));
    expect(state.api.updateStyle).not.toHaveBeenCalled();
  });
});
