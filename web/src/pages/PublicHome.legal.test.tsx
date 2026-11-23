// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';

vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ isAuthenticated: false, isLoading: false }) }));

afterEach(cleanup);

it('links to the privacy policy and terms from the home page', async () => {
  const { PublicHome } = await import('./PublicHome');
  render(<MemoryRouter><PublicHome /></MemoryRouter>);

  const legalNav = screen.getByRole('navigation', { name: 'Legal' });
  expect(within(legalNav).getByRole('link', { name: 'Privacy Policy' }).getAttribute('href')).toBe('/privacy');
  expect(within(legalNav).getByRole('link', { name: 'Terms of Service' }).getAttribute('href')).toBe('/terms');
});
