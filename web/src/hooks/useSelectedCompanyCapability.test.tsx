// @vitest-environment jsdom
import { cleanup, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { useOptionalSelectedCompanyCapability, useOptionalWorkerStatusAccess, useSelectedCompanyCapability } from './useSelectedCompanyCapability';

const state = vi.hoisted(() => ({
  company: null as CompanyListItem | null, id: 1 as number | null, loading: false, authLoading: false,
  map: {} as Record<string, string[]>, noProvider: false,
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: state.company, activeCompanyId: state.id, loading: state.loading }) }));
vi.mock('@/contexts/AuthContext', () => {
  const auth = () => ({
    isLoading: state.authLoading,
    // Global admin-like data must never be a fallback for a missing client grant.
    isAdmin: true, isManager: true, hasCapability: () => true,
    user: { role: 'accountant', company_capabilities: state.map },
  });
  return { useAuth: auth, useOptionalAuth: () => (state.noProvider ? undefined : auth()) };
});
const capability = 'manage_client_configuration';
const company = (id: number, capabilities?: string[]) => ({ id, client_capabilities: capabilities } as CompanyListItem);
beforeEach(() => { state.id = 1; state.company = company(1, [capability]); state.loading = false; state.authLoading = false; state.map = {}; state.noProvider = false; });
afterEach(cleanup);

describe('selected client capability isolation', () => {
  it('allows A, denies B, and never carries A access across a context switch', () => {
    const view = renderHook(() => useSelectedCompanyCapability(capability));
    expect(view.result.current).toBe(true);
    state.id = 2;
    view.rerender();
    expect(view.result.current).toBe(false);
    state.company = company(2, []);
    view.rerender();
    expect(view.result.current).toBe(false);
    state.id = 1; state.company = company(1, [capability]);
    view.rerender();
    expect(view.result.current).toBe(true);
  });
  it('uses only the actual active company key from auth and honors an explicit revocation in company data', () => {
    state.map = { 1: [capability], 2: [] };
    state.company = company(1);
    const view = renderHook(() => useSelectedCompanyCapability(capability));
    expect(view.result.current).toBe(true);
    state.company = company(1, []);
    view.rerender();
    expect(view.result.current).toBe(false);
    state.company = company(2); state.id = 2;
    view.rerender();
    expect(view.result.current).toBe(false);
  });
  it.each(['missing capabilities', 'missing company', 'missing selection', 'company loading', 'auth loading'] as const)('fails closed for %s', (condition) => {
    if (condition === 'missing capabilities') state.company = company(1);
    if (condition === 'missing company') state.company = null;
    if (condition === 'missing selection') state.id = null;
    if (condition === 'company loading') state.loading = true;
    if (condition === 'auth loading') state.authLoading = true;
    expect(renderHook(() => useSelectedCompanyCapability(capability)).result.current).toBe(false);
  });
  it('denies a retained form or employee belonging to another client', () => {
    const view = renderHook(({ resourceId }) => useSelectedCompanyCapability(capability, resourceId), { initialProps: { resourceId: 2 as number | null } });
    expect(view.result.current).toBe(false);
    view.rerender({ resourceId: 1 });
    expect(view.result.current).toBe(true);
    view.rerender({ resourceId: null });
    expect(view.result.current).toBe(false);
  });
  it('does not infer client administration from configuration or the grant boolean', () => {
    state.company = { ...company(1, [capability]), client_management: true };
    expect(renderHook(() => useSelectedCompanyCapability('manage_client_administration')).result.current).toBe(false);
  });
});

describe('optional selected client capability', () => {
  it('matches the required check inside the auth provider', () => {
    expect(renderHook(() => useOptionalSelectedCompanyCapability(capability, 1)).result.current).toBe(true);
    expect(renderHook(() => useOptionalSelectedCompanyCapability(capability, 2)).result.current).toBe(false);
  });
  it('fails closed outside the auth provider, even when company data grants it', () => {
    state.noProvider = true;
    expect(renderHook(() => useOptionalSelectedCompanyCapability(capability, 1)).result.current).toBe(false);
  });
});

describe('worker status access', () => {
  it('lets payroll staff reactivate but keeps rehiring with client configuration and writable workspaces', () => {
    state.company = company(1, ['manage_employee_status']);
    const view = renderHook(() => useOptionalWorkerStatusAccess(1));
    expect(view.result.current).toEqual({ canReactivate: true, canRehire: false });

    state.company = company(1, ['manage_employee_status', 'manage_client_configuration']);
    view.rerender();
    expect(view.result.current).toEqual({ canReactivate: true, canRehire: true });

    state.company = { ...company(1, ['manage_employee_status', 'manage_client_configuration']), workspace_can_write: false } as CompanyListItem;
    view.rerender();
    expect(view.result.current).toEqual({ canReactivate: false, canRehire: false });
  });
});
