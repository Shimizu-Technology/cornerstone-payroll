// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CompanyScopedRoute } from './CompanyScopedRoute';

const companyState = vi.hoisted(() => ({
  companies: [
    { id: 11, name: 'Browser Last Client' },
    { id: 22, name: 'Email Deep Link Client' },
  ],
  activeCompanyId: 11 as number | null,
  loading: false,
  scopeChangePending: false,
  switchCompany: vi.fn(),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => companyState,
}));

describe('CompanyScopedRoute deep link client selection', () => {
  afterEach(cleanup);
  beforeEach(() => {
    companyState.activeCompanyId = 11;
    companyState.loading = false;
    companyState.scopeChangePending = false;
    companyState.switchCompany.mockReset().mockImplementation((nextId: number) => {
      companyState.activeCompanyId = nextId;
      return true;
    });
  });

  it('switches from the browser last client to the link client before rendering the payroll review', async () => {
    const view = render(
      <MemoryRouter initialEntries={['/companies/22/pay-runs/99/overview']}>
        <Routes>
          <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
            <Route path="pay-runs/:id/:tab" element={<h1>Review for company 22</h1>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => expect(companyState.switchCompany).toHaveBeenCalledWith(22));
    // Re-render with the switched activeCompanyId (simulating context update).
    view.rerender(
      <MemoryRouter initialEntries={['/companies/22/pay-runs/99/overview']}>
        <Routes>
          <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
            <Route path="pay-runs/:id/:tab" element={<h1>Review for company 22</h1>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByRole('heading', { name: 'Review for company 22' })).toBeTruthy();
  });

  it('blocks access and offers a clear fallback to /app when the signed-in account lacks company access', () => {
    render(
      <MemoryRouter initialEntries={['/companies/999/pay-runs/99/overview']}>
        <Routes>
          <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
            <Route path="pay-runs/:id/:tab" element={<h1>Should not load</h1>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.queryByRole('heading', { name: 'Should not load' })).toBeNull();
    expect(screen.getByText('This client workspace could not be opened')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Go to dashboard' }).getAttribute('href')).toBe('/app');
    expect(companyState.switchCompany).not.toHaveBeenCalled();
  });
});
