// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { brandFrom } from './brand';
import { BrandContext, EmployeeAuthContext, EmployeeSessionContext, SignOutContext, type EmployeeAuthValue, type EmployeeSessionValue } from './contexts';
import { EmployerPicker } from './picker';
import { SignInScreen, WelcomeScreen } from './screens';
import { EmployeeShell } from './Shell';

afterEach(cleanup);

const noopAuth: EmployeeAuthValue = {
  isSignedIn: false,
  email: null,
  getToken: async () => null,
  signOut: async () => undefined,
  SignInForm: () => <div data-testid="sign-in-form">Form</div>,
  SignUpForm: () => <div data-testid="sign-up-form">Form</div>,
  stepUp: async (fn) => fn(),
  openAccountSettings: () => undefined,
  AccountSecurityPanel: () => <div />,
};

const readySession: EmployeeSessionValue = {
  state: {
    status: 'ready',
    link: { id: '1', companyName: 'Sunset Grill', subdomainSlug: 'sunset-grill', demo: true, status: 'active', formerAccessUntil: null, latestPayDate: null },
    links: [],
    info: { firstName: 'Ana', status: 'active', formerAccessUntil: null, nextPayday: null, w2Delivery: null, demo: true, features: { stubs: true, taxForms: true, profileRequests: false, deliveryConsent: false } },
  },
  api: {} as EmployeeSessionValue['api'],
  retry: vi.fn(),
  reportError: vi.fn(),
  chooseLink: vi.fn(),
  isFormer: false,
  isViewOnly: false,
  readOnly: false,
  memory: new Map(),
};

describe('Employee app D-3 Demo pills', () => {
  it('shows the Demo pill in the employee app header only when brand.demo is true', () => {
    const demoBrand = brandFrom({ name: 'Sunset Grill', logo_url: null, primary_color: null, accent_color: null, demo: true });
    const liveBrand = brandFrom({ name: 'Live Cafe', logo_url: null, primary_color: null, accent_color: null, demo: false });

    const { rerender } = render(
      <MemoryRouter>
        <BrandContext.Provider value={demoBrand}>
          <SignOutContext.Provider value={{ signOut: async () => true }}>
            <EmployeeSessionContext.Provider value={readySession}>
              <EmployeeShell><div>Body</div></EmployeeShell>
            </EmployeeSessionContext.Provider>
          </SignOutContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByText('Sunset Grill')).toBeTruthy();
    expect(screen.getByText('Demo')).toBeTruthy();

    rerender(
      <MemoryRouter>
        <BrandContext.Provider value={liveBrand}>
          <SignOutContext.Provider value={{ signOut: async () => true }}>
            <EmployeeSessionContext.Provider value={readySession}>
              <EmployeeShell><div>Body</div></EmployeeShell>
            </EmployeeSessionContext.Provider>
          </SignOutContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByText('Live Cafe')).toBeTruthy();
    expect(screen.queryByText('Demo')).toBeNull();
  });

  it('shows the Demo pill on the employee sign-in and welcome screens only for demo companies', () => {
    const demoBrand = brandFrom({ name: 'Sunset Grill', logo_url: null, primary_color: null, accent_color: null, demo: true });
    const liveBrand = brandFrom({ name: 'Live Cafe', logo_url: null, primary_color: null, accent_color: null, demo: false });

    const { rerender } = render(
      <MemoryRouter initialEntries={['/sign-in']}>
        <BrandContext.Provider value={demoBrand}>
          <EmployeeAuthContext.Provider value={noopAuth}>
            <SignInScreen />
          </EmployeeAuthContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByText('Sunset Grill')).toBeTruthy();
    expect(screen.getByText('Demo')).toBeTruthy();

    rerender(
      <MemoryRouter initialEntries={['/sign-in']}>
        <BrandContext.Provider value={liveBrand}>
          <EmployeeAuthContext.Provider value={noopAuth}>
            <SignInScreen />
          </EmployeeAuthContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByText('Live Cafe')).toBeTruthy();
    expect(screen.queryByText('Demo')).toBeNull();

    rerender(
      <MemoryRouter initialEntries={['/']}>
        <BrandContext.Provider value={demoBrand}>
          <EmployeeAuthContext.Provider value={noopAuth}>
            <WelcomeScreen />
          </EmployeeAuthContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByText('Demo')).toBeTruthy();
    const welcomeEmployer = screen.getByText('Sunset Grill');
    expect(welcomeEmployer.className).toContain('min-w-0');
    expect(welcomeEmployer.className).toContain('[overflow-wrap:anywhere]');
  });

  it('shows the Demo pill in the employer picker only for demo links and wraps long names', () => {
    render(
      <EmployerPicker
        links={[
          { id: '1', companyName: 'Live Cafe', subdomainSlug: 'live-cafe', demo: false, status: 'active', formerAccessUntil: null, latestPayDate: null },
          { id: '2', companyName: 'Sunset Grill', subdomainSlug: 'sunset-grill', demo: true, status: 'active', formerAccessUntil: null, latestPayDate: null },
        ]}
        onChoose={vi.fn()}
        onSignOut={vi.fn()}
      />,
    );
    expect(screen.getByText('Live Cafe')).toBeTruthy();
    const demoEmployer = screen.getByText('Sunset Grill');
    expect(demoEmployer.className).toContain('min-w-0');
    expect(demoEmployer.className).toContain('[overflow-wrap:anywhere]');
    expect(screen.getAllByText('Demo')).toHaveLength(1);
  });
});
