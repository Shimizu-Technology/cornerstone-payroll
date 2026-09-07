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

import { apiClient, employeesApi, payrollItemsApi, setAuthToken, setAuthTokenProvider } from './api';

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
});
