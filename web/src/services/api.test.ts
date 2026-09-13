import { afterEach, describe, expect, it, vi } from 'vitest';

vi.hoisted((): void => {
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (): null => null,
      setItem: (): void => undefined,
      removeItem: (): void => undefined,
    },
  });
});

import { apiClient, employeesApi, payPeriodsApi, payrollItemsApi, reportsApi, setAuthToken, setAuthTokenProvider, timeTrackingSourcesApi } from './api';

describe('ApiClient company identity', (): void => {
  afterEach((): void => {
    setAuthTokenProvider(null);
    setAuthToken(null);
    apiClient.setActiveCompanyId(null);
    vi.restoreAllMocks();
  });

  it('keeps the initiating company while auth token resolution is pending', async (): Promise<void> => {
    let markTokenRequested: (() => void) | undefined;
    const tokenRequested = new Promise<void>((resolve): void => {
      markTokenRequested = resolve;
    });
    let releaseToken: (() => void) | undefined;
    const tokenReleased = new Promise<string | null>((resolve): void => {
      releaseToken = (): void => resolve('test-token');
    });
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    setAuthTokenProvider((): Promise<string | null> => {
      markTokenRequested?.();
      return tokenReleased;
    });
    apiClient.setActiveCompanyId(7);
    const pendingRequest = apiClient.get<{ ok: boolean }>('/test-company-snapshot');
    await tokenRequested;

    apiClient.setActiveCompanyId(12);
    releaseToken?.();
    await expect(pendingRequest).resolves.toEqual({ ok: true });

    const headers = new Headers(fetchMock.mock.calls[0][1]?.headers);
    expect(headers.get('X-Company-Id')).toBe('7');
    expect(headers.get('Authorization')).toBe('Bearer test-token');
  });

  it('honors an explicit company override and permits company-neutral requests', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (): Promise<Response> => (
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    ));

    apiClient.setActiveCompanyId(7);
    await apiClient.get<{ ok: boolean }>('/explicit-company', undefined, { companyId: 12 });
    await apiClient.get<{ ok: boolean }>('/company-neutral', undefined, { companyId: null });

    const overrideHeaders = new Headers(fetchMock.mock.calls[0][1]?.headers);
    const neutralHeaders = new Headers(fetchMock.mock.calls[1][1]?.headers);
    expect(overrideHeaders.get('X-Company-Id')).toBe('12');
    expect(neutralHeaders.has('X-Company-Id')).toBe(false);
  });

  it('scopes employee and payroll-item detail wrappers to an explicit or active company', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (): Promise<Response> => (
      new Response(JSON.stringify({ data: {}, payroll_item: {} }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    ));

    apiClient.setActiveCompanyId(7);
    await employeesApi.get(10, 12);
    await payrollItemsApi.get(20, 30, 12);
    await employeesApi.get(10);
    await payrollItemsApi.get(20, 30);

    expect(new Headers(fetchMock.mock.calls[0][1]?.headers).get('X-Company-Id')).toBe('12');
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get('X-Company-Id')).toBe('12');
    expect(new Headers(fetchMock.mock.calls[2][1]?.headers).get('X-Company-Id')).toBe('7');
    expect(new Headers(fetchMock.mock.calls[3][1]?.headers).get('X-Company-Id')).toBe('7');
  });

  it('records filing responsibility through the company-scoped review endpoint', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ data: [], filing_gate: {}, permissions: {} }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    apiClient.setActiveCompanyId(7);
    await reportsApi.updatePayrollFilingResponsibility({
      tax_year: 2026,
      quarter: 2,
      filing_types: ['form_941'],
      responsible_party: 'cornerstone',
      imported_payroll_inclusion: 'included',
      notes: 'Reviewed against locked QuickBooks payroll.',
    });

    expect(fetchMock).toHaveBeenCalledOnce();
    const [, options] = fetchMock.mock.calls[0];
    expect(options?.method).toBe('PUT');
    expect(new Headers(options?.headers).get('X-Company-Id')).toBe('7');
    expect(JSON.parse(String(options?.body))).toEqual({
      responsibility: {
        tax_year: 2026,
        quarter: 2,
        filing_types: ['form_941'],
        responsible_party: 'cornerstone',
        imported_payroll_inclusion: 'included',
        notes: 'Reviewed against locked QuickBooks payroll.',
      },
    });
  });

  it('keeps an AIRE time-entry identifier inside one approval path segment', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ command: { id: 'test', replayed: false } }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await payPeriodsApi.reviewAireTimeEntry(17, '42/../../entries?all=true', {
      command_id: '0f5c1e56-2831-4b3f-b991-3dfaa3c51c24',
      expected_version: 2,
      decision: 'approve',
      reason: 'Verified source entry',
    });

    expect(String(fetchMock.mock.calls[0][0])).toContain(
      '/pay_periods/17/aire_payroll_cockpit/time_entries/42%2F..%2F..%2Fentries%3Fall%3Dtrue/approval',
    );
  });

  it('sends source settings and delegated AIRE access in one update request', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ time_tracking_source: { id: 4 } }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await timeTrackingSourcesApi.update(4, {
      name: 'AIRE',
      base_url: 'https://aire.example.com',
      active: true,
      delegation_token: 'personal-token',
    });

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({
      time_tracking_source: {
        name: 'AIRE',
        base_url: 'https://aire.example.com',
        active: true,
        delegation_token: 'personal-token',
      },
    });
  });

  it('uses the expected contracts for AIRE delegation and cockpit requests', async (): Promise<void> => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => (
      new Response(JSON.stringify({}), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    ));
    const command = {
      command_id: '0f5c1e56-2831-4b3f-b991-3dfaa3c51c24',
      expected_version: 2,
      reason: 'Cutoff review complete',
    };

    await timeTrackingSourcesApi.saveDelegation(4, 'personal-token');
    await timeTrackingSourcesApi.removeDelegation(4);
    await payPeriodsApi.airePayrollCockpit(17, { employee_page: 2 });
    await payPeriodsApi.airePayrollTimeEntries(17, { employee_id: '91', approval_status: 'pending', page: 3 });
    await payPeriodsApi.airePayrollExceptions(17, { page: 4, leave_page: 5 });
    await payPeriodsApi.finalizeAirePayrollPeriod(17, command);

    const calls = fetchMock.mock.calls.map(([input, options]) => ({
      url: new URL(String(input)),
      method: options?.method,
      body: options?.body ? JSON.parse(String(options.body)) : undefined,
    }));
    expect(calls[0]).toMatchObject({
      method: 'PUT',
      body: { delegation_token: 'personal-token' },
    });
    expect(calls[0].url.pathname).toContain('/admin/time_tracking_sources/4/delegation');
    expect(calls[1].method).toBe('DELETE');
    expect(calls[1].url.pathname).toContain('/admin/time_tracking_sources/4/delegation');
    expect(Object.fromEntries(calls[2].url.searchParams)).toEqual({ employee_page: '2', employee_per_page: '100' });
    expect(Object.fromEntries(calls[3].url.searchParams)).toEqual({
      employee_id: '91', approval_status: 'pending', page: '3', per_page: '250',
    });
    expect(Object.fromEntries(calls[4].url.searchParams)).toEqual({
      page: '4', leave_page: '5', per_page: '250', leave_per_page: '100',
    });
    expect(calls[5]).toMatchObject({ method: 'POST', body: command });
    expect(calls[5].url.pathname).toContain('/admin/pay_periods/17/aire_payroll_cockpit/finalize');
  });
});
