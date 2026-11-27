// @vitest-environment jsdom
import { act, cleanup, render, screen } from '@testing-library/react';
import { useEffect } from 'react';
import { MemoryRouter, Route, Routes, useNavigate, type NavigateFunction } from 'react-router';
import { afterEach, describe, expect, it } from 'vitest';
import { brandFrom } from './brand';
import { BrandContext, EmployeeAuthContext, type EmployeeAuthValue } from './contexts';
import { SignInScreen } from './screens';

afterEach(cleanup);

const auth: EmployeeAuthValue = {
  isSignedIn: false,
  email: null,
  getToken: async () => null,
  signOut: async () => undefined,
  SignInForm: ({ redirectTo }) => <div data-testid="sign-in-form">{redirectTo}</div>,
  SignUpForm: () => <div />,
  stepUp: async (fn) => fn(),
  openAccountSettings: () => undefined,
  AccountSecurityPanel: () => <div />,
};

let navigate: NavigateFunction = () => undefined;
function CaptureNavigate() {
  const next = useNavigate();
  useEffect(() => { navigate = next; }, [next]);
  return null;
}

describe('SignInScreen', () => {
  it('keeps the invite return path when Clerk moves to a hash step without router state', () => {
    const brand = brandFrom({ name: 'Sunset Grill', logo_url: null, primary_color: null, accent_color: null, demo: false });
    render(
      <MemoryRouter initialEntries={[{ pathname: '/sign-in', state: { from: '/claim' } }]}>
        <BrandContext.Provider value={brand}>
          <EmployeeAuthContext.Provider value={auth}>
            <CaptureNavigate />
            <Routes><Route path="/sign-in" element={<SignInScreen />} /></Routes>
          </EmployeeAuthContext.Provider>
        </BrandContext.Provider>
      </MemoryRouter>,
    );
    expect(screen.getByTestId('sign-in-form').textContent).toBe('/claim');

    // The new-device code step (#/client-trust) replaces the entry with no state.
    act(() => { navigate('/sign-in#/client-trust', { replace: true }); });
    expect(screen.getByTestId('sign-in-form').textContent).toBe('/claim');
  });
});
