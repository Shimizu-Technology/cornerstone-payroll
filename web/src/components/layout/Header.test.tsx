// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Header } from './Header';

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompany: { id: 3, name: 'Harbor Finch Kitchen' } }),
}));

afterEach(cleanup);

describe('Header', () => {
  it('shows the active client on client pages', () => {
    render(<Header title="Employees" />);
    expect(screen.getByText('Client')).toBeTruthy();
    expect(screen.getByText('Harbor Finch Kitchen')).toBeTruthy();
  });

  it('hides the client chip on organization-wide pages', () => {
    render(<Header title="User Management" organizationWide />);
    expect(screen.queryByText('Client')).toBeNull();
    expect(screen.queryByText('Harbor Finch Kitchen')).toBeNull();
  });

  it('still shows an explicit workspace label on organization-wide pages', () => {
    render(<Header title="Year-end" organizationWide contextLabel="Organization" contextValue="Cornerstone Tax Services" />);
    expect(screen.getByText('Cornerstone Tax Services')).toBeTruthy();
  });
});
