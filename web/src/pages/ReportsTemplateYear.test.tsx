// @vitest-environment jsdom
import type { ReactNode } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, useNavigate } from 'react-router';
import { PdfPreviewProvider } from '@/components/documents/PdfPreview';
import type { ReportDownloadFormat } from '@/components/reports/ReportDownloadMenu';
import { Form941GuPanel, QuarterlyCompliancePacketPanel } from './Reports';
import { PeriodKeyed } from '@/lib/report-period';

const mocks = vi.hoisted(() => ({ worksheet: vi.fn(), packet: vi.fn(), pdf: vi.fn(), packetPdf: vi.fn(), xlsx: vi.fn(), defaults: vi.fn() }));
vi.mock('@/services/api', () => ({
  reportsApi: { form941Gu: mocks.worksheet, quarterlyCompliancePacket: mocks.packet, form941GuPdf: mocks.pdf,
    quarterlyCompliancePacketPdf: mocks.packetPdf, form941GuXlsx: mocks.xlsx, quarterlyCompliancePacketOfficialFormDefaults: mocks.defaults },
  ApiError: class extends Error {},
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 42 }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1 } }) }));
// Exercise actual panel gating/callbacks without emulating the browser's Popover API.
vi.mock('@/components/reports/ReportDownloadMenu', () => ({ ReportDownloadMenu: ({ formats }: { formats: ReportDownloadFormat[] }) =>
  <div>{formats.map((format) => <button key={format.key} onClick={() => void format.onSelect()}>{format.label}</button>)}</div> }));

const message = 'Official Form 941 PDFs are available only for tax year 2026. For 2025, use the worksheet or reconciliation workbook and obtain the matching IRS Form 941 revision.';
const meta = (year: number) => ({ year, quarter: 2, company_name: 'Synthetic review', quarter_label: `Q2 ${year}`, caveats: [] });
const status = (available: boolean) => ({ available, supported_tax_years: [2026], message: available ? null : message });
const worksheet = (year: number, available: boolean) => ({ meta: meta(year), official_form_template: status(available),
  filing_readiness: { message: 'Review required', blockers: [] }, employer_info: { name: 'Synthetic review' }, lines: {}, tax_detail: {} });
const packet = (year: number, available: boolean) => ({ meta: meta(year), official_form_template: status(available),
  review_checks: [], due_dates: {}, filing_gate: { filings: {}, blockers: [], source_coverage: { has_historical_payroll: false } }, w1: { total_guam_withholding: 0, monthly_liabilities: [] },
  swica: { totals: { total_wages: 0, employee_count: 0 }, employees: [] },
  federal_941: { deposit_schedule: {}, report: { lines: {} } } });

function mount(panel: ReactNode, path = '/reports') {
  return render(<MemoryRouter initialEntries={[path]}><PdfPreviewProvider>{panel}</PdfPreviewProvider></MemoryRouter>);
}
afterEach(() => { cleanup(); vi.clearAllMocks(); });

describe('A linked year and quarter', () => {
  it('opens the Form 941 for the year and quarter the year-end checklist names', async () => {
    mocks.worksheet.mockResolvedValue({ report: worksheet(2025, false) });
    mount(<Form941GuPanel />, '/reports?report=941-gu&year=2025&quarter=1');
    expect(screen.getByLabelText('Year')).toHaveProperty('value', '2025');
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', '1');
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    await screen.findByText(message);
    expect(mocks.worksheet).toHaveBeenCalledWith(2025, 1);
  });

  it('opens the quarterly packet (the W-1 source) for the linked period', async () => {
    mocks.packet.mockResolvedValue({ report: packet(2025, false) });
    mount(<QuarterlyCompliancePacketPanel />, '/reports?report=quarterly-compliance-packet&year=2025&quarter=3');
    fireEvent.click(screen.getByRole('button', { name: 'View Packet' }));
    await screen.findByText(message);
    expect(mocks.packet).toHaveBeenCalledWith(2025, 3);
  });

  function Nav() {
    const navigate = useNavigate();
    return <>
      <button onClick={() => navigate('/reports?report=941-gu&year=2025&quarter=3')}>To Q3</button>
      <button onClick={() => navigate('/reports?report=941-gu&year=2026&quarter=1')}>To 2026 Q1</button>
      <button onClick={() => navigate(-1)}>Back</button>
    </>;
  }
  const mountLinked = (path: string) => render(<MemoryRouter initialEntries={[path]}><PdfPreviewProvider><Nav /><PeriodKeyed><Form941GuPanel /></PeriodKeyed></PdfPreviewProvider></MemoryRouter>);

  it('follows the URL when it changes after the panel mounted (Back/Forward)', () => {
    mountLinked('/reports?report=941-gu&year=2025&quarter=1');
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', '1');
    fireEvent.click(screen.getByRole('button', { name: 'To Q3' }));
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', '3');
    fireEvent.click(screen.getByRole('button', { name: 'Back' }));
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', '1');
    expect(screen.getByLabelText('Year')).toHaveProperty('value', '2025');
  });

  it('reapplies an unchanged quarter from the URL and drops the old period\'s report on navigation', async () => {
    mocks.worksheet.mockResolvedValue({ report: worksheet(2025, false) });
    mountLinked('/reports?report=941-gu&year=2025&quarter=1');
    fireEvent.change(screen.getByLabelText('Quarter'), { target: { value: '2' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    await screen.findByText(message);

    fireEvent.click(screen.getByRole('button', { name: 'To 2026 Q1' }));
    expect(screen.getByLabelText('Year')).toHaveProperty('value', '2026');
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', '1');
    expect(screen.queryByText(message)).toBeNull();
  });

  it('does not show a PDF that arrives after the URL period changed', async () => {
    mocks.worksheet.mockResolvedValue({ report: worksheet(2026, true) });
    let resolvePdf: (value: { blob: Blob; filename: string }) => void = () => {};
    mocks.pdf.mockReturnValue(new Promise((resolve) => { resolvePdf = resolve; }));
    mountLinked('/reports?report=941-gu&year=2026&quarter=1');
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Preview draft Form 941' }));
    await waitFor(() => expect(mocks.pdf).toHaveBeenCalledWith(2026, 1));

    fireEvent.click(screen.getByRole('button', { name: 'To Q3' }));
    await act(async () => { resolvePdf({ blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }), filename: 'q1.pdf' }); });

    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('keeps its own default for a period it cannot show', () => {
    mount(<Form941GuPanel />, '/reports?report=941-gu&year=1999&quarter=9');
    expect(screen.getByLabelText('Year')).toHaveProperty('value', String(new Date().getFullYear()));
    expect(screen.getByLabelText('Quarter')).toHaveProperty('value', String(Math.ceil((new Date().getMonth() + 1) / 3)));
  });
});

describe('Official Form 941 tax-year availability', () => {
  it('retains the 2025 worksheet and spreadsheet while explaining unavailable official PDF', async () => {
    mocks.worksheet.mockResolvedValue({ report: worksheet(2025, false) });
    mount(<Form941GuPanel />);
    fireEvent.change(screen.getByLabelText('Year'), { target: { value: '2025' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    expect(await screen.findByText(message)).toBeTruthy();
    expect(screen.getByText('Federal Form 941 — Q2 2025')).toBeTruthy();
    expect(screen.getByRole('button', { name: '941 worksheet (.xlsx)' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Preview draft Form 941' })).toBeNull();
    expect(mocks.pdf).not.toHaveBeenCalled();
  });

  it('enables a supported preview only after server availability, and clears it when the selected year changes', async () => {
    mocks.worksheet.mockResolvedValue({ report: worksheet(2026, true) });
    mount(<Form941GuPanel />);
    expect(screen.queryByRole('button', { name: 'Preview draft Form 941' })).toBeNull();
    fireEvent.change(screen.getByLabelText('Year'), { target: { value: '2026' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    expect(await screen.findByRole('button', { name: 'Preview draft Form 941' })).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Year'), { target: { value: '2025' } });
    expect(screen.queryByRole('button', { name: 'Preview draft Form 941' })).toBeNull();
    expect(screen.getByLabelText('Year')).toHaveProperty('value', '2025');
  });

  it('fails closed with a recovery message when template metadata is unavailable', async () => {
    mocks.worksheet.mockResolvedValue({ report: { ...worksheet(2026, true), official_form_template: undefined } });
    mount(<Form941GuPanel />);
    fireEvent.change(screen.getByLabelText('Year'), { target: { value: '2026' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Worksheet' }));
    await screen.findByText('Federal Form 941 — Q2 2026');
    expect(screen.getByText(/If availability remains unknown, reload the report/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Preview draft Form 941' })).toBeNull();
    expect(screen.getByRole('button', { name: '941 worksheet (.xlsx)' })).toBeTruthy();
  });

  it('blocks the whole 2025 PDF packet and 941 review while keeping other government forms and workbook reachable', async () => {
    mocks.packet.mockResolvedValue({ report: packet(2025, false) });
    mount(<QuarterlyCompliancePacketPanel />);
    fireEvent.change(screen.getByLabelText('Year'), { target: { value: '2025' } });
    fireEvent.click(screen.getByRole('button', { name: 'View Packet' }));
    expect(await screen.findByText(message)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Review 941' })).toHaveProperty('disabled', true);
    for (const name of ['Review Schedule B', 'Review W-1', 'Review SW-2', 'Reconciliation workbook (.xlsx)']) {
      expect(screen.getByRole('button', { name })).toHaveProperty('disabled', false);
    }
    expect(screen.queryByRole('button', { name: 'Preview draft PDF packet' })).toBeNull();
    expect(mocks.packetPdf).not.toHaveBeenCalled();
  });
});

it('shows missing employee details in the packet and preserves draft preview actions', async () => {
  mocks.packet.mockResolvedValue({ report: { ...packet(2026, true), employee_completeness: {
    missing_ssn_count: 1, missing_address_count: 1, message: 'Missing details print blank. Drafts can still be generated.',
    employees: [{ employee_id: 7, name: 'Synthetic Worker', missing_fields: ['ssn', 'address'], edit_path: '/companies/42/employees/7/edit' }],
  } } });
  mount(<QuarterlyCompliancePacketPanel />);
  fireEvent.click(screen.getByRole('button', { name: 'View Packet' }));
  expect(await screen.findByText('Synthetic Worker — missing 9-digit SSN and complete address')).toBeTruthy();
  expect(screen.getByRole('link', { name: /Edit profile for Synthetic Worker/ }).getAttribute('href')).toBe('/companies/42/employees/7/edit');
  expect(screen.getByRole('button', { name: /Review.*SW-2/i })).toBeTruthy();
});

it('keeps the government-form review layout without asserting unsupported modal focus behavior', async () => {
  mocks.packet.mockResolvedValue({ report: packet(2026, true) });
  mocks.defaults.mockResolvedValue({ data: { title: 'SW-2', employees: [] } });
  mount(<QuarterlyCompliancePacketPanel />);
  fireEvent.click(screen.getByRole('button', { name: 'View Packet' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Review SW-2' }));
  const dialog = await screen.findByRole('dialog', { name: 'Government form review' });
  expect(dialog.hasAttribute('aria-modal')).toBe(false);
  expect(dialog.className).toContain('w-[min(1600px,calc(100vw-1.5rem))]');
  fireEvent.click(screen.getByRole('button', { name: 'Close' }));
  expect(screen.queryByRole('dialog')).toBeNull();
});
