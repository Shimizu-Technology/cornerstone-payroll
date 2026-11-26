// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Header } from './Header';

const activeCompany = vi.hoisted(() => ({ current: { id: 3, name: 'Harbor Finch Kitchen', demo: false } as { id: number; name: string; demo?: boolean } }));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompany: activeCompany.current }),
}));

beforeEach(() => {
  activeCompany.current = { id: 3, name: 'Harbor Finch Kitchen', demo: false };
});

afterEach(cleanup);

describe('Header', () => {
  it('shows the active client on client pages without a Demo pill for real companies', () => {
    render(<Header title="Employees" />);
    expect(screen.getByText('Client')).toBeTruthy();
    expect(screen.getByText('Harbor Finch Kitchen')).toBeTruthy();
    expect(screen.queryByText('Demo')).toBeNull();
  });

  it('shows a grey Demo pill next to the client name when activeCompany.demo is true', () => {
    activeCompany.current = { id: 7, name: 'Sunset Grill', demo: true };
    render(<Header title="Employees" />);
    expect(screen.getByText('Sunset Grill')).toBeTruthy();
    expect(screen.getByText('Demo')).toBeTruthy();
  });

  it('hides the client chip and Demo pill on organization-wide pages', () => {
    activeCompany.current = { id: 7, name: 'Sunset Grill', demo: true };
    render(<Header title="User Management" organizationWide />);
    expect(screen.queryByText('Client')).toBeNull();
    expect(screen.queryByText('Sunset Grill')).toBeNull();
    expect(screen.queryByText('Demo')).toBeNull();
  });

  it('still shows an explicit workspace label on organization-wide pages', () => {
    render(<Header title="Year-end" organizationWide contextLabel="Organization" contextValue="Cornerstone Tax Services" />);
    expect(screen.getByText('Cornerstone Tax Services')).toBeTruthy();
    expect(screen.queryByText('Demo')).toBeNull();
  });
});
