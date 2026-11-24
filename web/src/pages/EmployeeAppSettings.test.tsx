// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import type { EmployeeAppSettings as Settings, HelpContact } from '@/services/employee-app-settings-api';
import { EmployeeAppSettings } from './EmployeeAppSettings';

const mocks = vi.hoisted(() => ({
  role: 'client' as string,
  capabilities: [] as string[],
  audiences: [] as string[],
  get: vi.fn(),
  updateBranding: vi.fn(),
  updateHelpContacts: vi.fn(),
  uploadLogo: vi.fn(),
  removeLogo: vi.fn(),
  logo: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 7, role: mocks.role }, isLoading: false, hasCapability: () => false }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompany: { id: 6, name: 'Example Grill LLC', client_capabilities: mocks.capabilities } as unknown as CompanyListItem,
    activeCompanyId: 6,
    loading: false,
  }),
}));
vi.mock('@/services/employee-app-settings-api', () => ({
  employeeAppSettingsApi: (audience: string) => {
    mocks.audiences.push(audience);
    return {
      get: mocks.get, updateBranding: mocks.updateBranding, updateHelpContacts: mocks.updateHelpContacts,
      uploadLogo: mocks.uploadLogo, removeLogo: mocks.removeLogo, logo: mocks.logo,
    };
  },
}));

function settings(overrides: Partial<Settings> = {}, contacts: HelpContact[] = []): Settings {
  return {
    company_id: 6,
    company_name: 'Example Grill LLC',
    branding: {
      display_name: null, app_name: null, primary_color: null, accent_color: null, show_main_phone: true,
      logo: null, external_logo_url: null,
    },
    main_phone: '6715550100',
    subdomain: { slug: 'example-grill', host: 'example-grill.shimizu-technology.com' },
    help_contacts: contacts,
    max_help_contacts: 5,
    logo_limits: { max_bytes: 1048576, content_types: ['image/png', 'image/webp'] },
    ...overrides,
  };
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/companies/6/employee-app']}>
      <Routes>
        <Route path="/companies/:companyId/employee-app" element={<EmployeeAppSettings />} />
        <Route path="/app" element={<p>Dashboard</p>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.role = 'client';
  mocks.capabilities = [];
  mocks.audiences = [];
  mocks.get.mockResolvedValue({ data: settings() });
  mocks.logo.mockRejectedValue(new Error('none'));
});
afterEach(cleanup);

describe('EmployeeAppSettings', () => {
  it('warns when Help contacts are missing and shows what employees see instead', async () => {
    renderPage();

    expect(await screen.findByText('Help contacts not set up')).toBeTruthy();
    expect(screen.getByText(/employees who need help see: “Ask your manager at Example Grill LLC/)).toBeTruthy();
    expect(screen.getByText(/button to call \(671\) 555-0100/)).toBeTruthy();
    expect(mocks.audiences).toContain('client');
    expect(mocks.get).toHaveBeenCalledWith(6);
  });

  it('explains the button shade for a light brand color and saves through the client endpoint', async () => {
    const user = userEvent.setup();
    mocks.updateBranding.mockImplementation(async (_company: number, branding: Record<string, unknown>) => ({
      data: settings({ branding: { ...settings().branding, ...branding, show_main_phone: true } as Settings['branding'] }),
    }));
    renderPage();
    await screen.findByText('Help contacts not set up');

    fireEvent.change(screen.getByLabelText('Brand color'), { target: { value: '#1898CF' } });
    expect(screen.getByText('Buttons will use this darker shade so text is readable.')).toBeTruthy();
    expect(screen.getByText(/White text on your color: 3.2 to 1/)).toBeTruthy();

    fireEvent.change(screen.getByLabelText('Brand color'), { target: { value: '#FADF06' } });
    expect(screen.getByText(/too light for white text/)).toBeTruthy();

    await user.type(screen.getByLabelText('Home Screen name'), "Grill's Pay Stubs");
    expect(screen.getByText(/cut this off after about 12 characters/)).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(mocks.updateBranding).toHaveBeenCalledWith(6, {
      display_name: '', app_name: "Grill's Pay Stubs", primary_color: '#FADF06', accent_color: '', show_main_phone: true,
    }));
    expect(await screen.findByText(/Employees see the new look/)).toBeTruthy();
  });

  it('checks the accent even without a brand color', async () => {
    renderPage();
    await screen.findByText('Help contacts not set up');

    fireEvent.change(screen.getByLabelText('Accent color (optional)'), { target: { value: '#FADF06' } });

    expect(screen.getByText('Highlights use this color with dark text.')).toBeTruthy();
    expect(screen.getByText('Without a brand color, the app uses Cornerstone Payroll blue.')).toBeTruthy();
  });

  it('refuses an SVG before uploading and recommends a square PNG or WebP', async () => {
    const user = userEvent.setup({ applyAccept: false });
    renderPage();
    await screen.findByText('Help contacts not set up');
    expect(screen.getByText(/Square, at least 512×512, works best/)).toBeTruthy();

    await user.upload(screen.getByLabelText('Logo file'), new File(['<svg/>'], 'logo.svg', { type: 'image/svg+xml' }));

    expect(await screen.findByText("Upload a PNG or WebP image. SVG isn't supported.")).toBeTruthy();
    expect(mocks.uploadLogo).not.toHaveBeenCalled();
  });

  it('trusts the file name only when the browser gives no specific type', async () => {
    const user = userEvent.setup({ applyAccept: false });
    mocks.uploadLogo.mockResolvedValue({ data: settings() });
    renderPage();
    await screen.findByText('Help contacts not set up');
    const input = screen.getByLabelText('Logo file');

    await user.upload(input, new File(['<svg/>'], 'logo.png', { type: 'image/svg+xml' }));
    expect(await screen.findByText("Upload a PNG or WebP image. SVG isn't supported.")).toBeTruthy();
    expect(mocks.uploadLogo).not.toHaveBeenCalled();

    await user.upload(input, new File(['png'], 'logo.png', { type: '' }));
    await waitFor(() => expect(mocks.uploadLogo).toHaveBeenCalledTimes(1));
    await user.upload(input, new File(['webp'], 'logo.webp', { type: 'application/octet-stream' }));
    await waitFor(() => expect(mocks.uploadLogo).toHaveBeenCalledTimes(2));
  });

  it('locks the branding fields while a save is in flight so later typing is not lost', async () => {
    const user = userEvent.setup();
    let finish: (value: { data: Settings }) => void = () => {};
    mocks.updateBranding.mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    renderPage();
    await screen.findByText('Help contacts not set up');
    const name = screen.getByLabelText('Name employees see') as HTMLInputElement;

    await user.type(name, 'Example Grill');
    await user.click(screen.getByRole('button', { name: /Save changes|Saving/ }));

    expect(await screen.findByText(/Saving… Fields unlock when it's done./)).toBeTruthy();
    expect(name.disabled).toBe(true);
    expect((screen.getByLabelText('Brand color') as HTMLInputElement).disabled).toBe(true);

    finish({ data: settings({ branding: { ...settings().branding, display_name: 'Example Grill' } }) });
    await waitFor(() => expect(name.disabled).toBe(false));
    expect(name.value).toBe('Example Grill');
  });

  it('fetches the saved logo for the shown company and lets admins remove a legacy logo', async () => {
    const user = userEvent.setup();
    mocks.get.mockResolvedValue({ data: settings({ branding: { ...settings().branding, external_logo_url: 'https://images.example.test/grill.png' } }) });
    mocks.removeLogo.mockResolvedValue({ data: settings() });
    renderPage();
    await screen.findByText('Help contacts not set up');

    await user.click(screen.getByRole('button', { name: 'Remove' }));

    await waitFor(() => expect(mocks.removeLogo).toHaveBeenCalledWith(6));
    expect(mocks.logo).not.toHaveBeenCalled();

    cleanup();
    mocks.get.mockResolvedValue({ data: settings({ branding: { ...settings().branding, logo: { content_type: 'image/png', byte_size: 900, digest: 'abc' } } }) });
    renderPage();
    await screen.findByText('Help contacts not set up');
    await waitFor(() => expect(mocks.logo).toHaveBeenCalledWith(6));
  });

  it('blocks saving an invalid color code', async () => {
    renderPage();
    await screen.findByText('Help contacts not set up');

    fireEvent.change(screen.getByLabelText('Accent color (optional)'), { target: { value: '#FAD' } });

    expect(screen.getByText('Use a six-digit color code like #1898CF.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Save changes' }).matches(':disabled')).toBe(true);
  });

  it('adds, checks and saves Help contacts in order', async () => {
    const user = userEvent.setup();
    mocks.updateHelpContacts.mockImplementation(async (_company: number, contacts: HelpContact[]) => ({ data: settings({}, contacts) }));
    renderPage();
    await user.click(await screen.findByRole('button', { name: 'Set up Help contacts' }));

    await user.click(screen.getByRole('button', { name: 'Save Help contacts' }));
    expect(screen.getByText('Add a name.')).toBeTruthy();
    expect(screen.getByText(/Add a phone number or an email/)).toBeTruthy();
    expect(mocks.updateHelpContacts).not.toHaveBeenCalled();

    const list = screen.getByRole('list', { name: /Help contacts/ });
    await user.type(within(list).getByLabelText('Name'), 'Avery Example');
    await user.type(within(list).getByLabelText('Phone'), '671-555-0111');
    await user.click(within(list).getByRole('checkbox', { name: /Employees can text this number/ }));
    await user.click(screen.getByRole('button', { name: 'Add another contact' }));
    const names = within(list).getAllByLabelText('Name');
    await user.type(names[1], 'Riley Example');
    await user.type(within(list).getAllByLabelText('Email')[1], 'riley@example.test');
    await user.click(screen.getByRole('button', { name: 'Move Riley Example up' }));

    await user.click(screen.getByRole('button', { name: 'Save Help contacts' }));
    await waitFor(() => expect(mocks.updateHelpContacts).toHaveBeenCalledWith(6, [
      { name: 'Riley Example', role: null, phone: null, email: 'riley@example.test', text_ok: false },
      { name: 'Avery Example', role: null, phone: '671-555-0111', email: null, text_ok: true },
    ]));
    expect(await screen.findByText('Help contacts saved.')).toBeTruthy();
    expect(screen.queryByText('Help contacts not set up')).toBeNull();
  });

  it('shows the server problem next to the contact it belongs to', async () => {
    const user = userEvent.setup();
    const { ApiError } = await import('@/services/api');
    mocks.get.mockResolvedValue({ data: settings({}, [{ name: 'Avery Example', role: null, phone: '671-555-0111', email: null, text_ok: false }]) });
    mocks.updateHelpContacts.mockRejectedValue(new ApiError('Check the Help contacts', 422, undefined, {
      details: { help_contacts: { 0: ['Phone needs 7 to 15 digits'] } },
    }));
    renderPage();
    const list = await screen.findByRole('list', { name: /Help contacts/ });
    await user.type(within(list).getByLabelText('Role (optional)'), 'Owner');

    await user.click(screen.getByRole('button', { name: 'Save Help contacts' }));

    expect(await screen.findByText('Phone needs 7 to 15 digits')).toBeTruthy();
  });

  it('uses the staff endpoint for Cornerstone staff with client administration', async () => {
    mocks.role = 'admin';
    mocks.capabilities = ['manage_client_administration'];
    renderPage();

    await screen.findByText('Help contacts not set up');
    expect(mocks.audiences).toContain('staff');
    expect(mocks.audiences).not.toContain('client');
  });

  it('sends staff without client administration back to the dashboard', async () => {
    mocks.role = 'accountant';
    mocks.capabilities = [];
    renderPage();

    expect(await screen.findByText('Dashboard')).toBeTruthy();
    expect(mocks.get).not.toHaveBeenCalled();
  });

  it('previews the phone and desktop screens with unsaved changes', async () => {
    const user = userEvent.setup();
    renderPage();
    await screen.findByText('Help contacts not set up');
    await user.type(screen.getByLabelText('Name employees see'), 'Example Grill');

    expect(screen.getByRole('img', { name: /Sign-in screen on a phone/ })).toBeTruthy();
    await user.click(screen.getByRole('radio', { name: 'Help' }));
    await user.click(screen.getByRole('radio', { name: /Desktop/ }));
    expect(screen.getByRole('img', { name: /Help screen on a desktop/ })).toBeTruthy();
    expect(screen.getByRole('img', { name: 'Home Screen icon labeled Example Grill' })).toBeTruthy();
  });
});
