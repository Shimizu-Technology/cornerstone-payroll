// @vitest-environment jsdom
import { createHash } from 'node:crypto';
import { cleanup, render } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { CaptureResult } from 'posthog-js';
import {
  DEFAULT_POSTHOG_HOST,
  DEFAULT_POSTHOG_ID_SALT,
  buildPostHogConfig,
  capturePageView,
  createBeforeSend,
  hasPrivacyOptOutSignal,
  identifyUser,
  initAnalytics,
  isSensitivePropertyKey,
  pseudonymousUserId,
  scrubPathname,
  scrubUrl,
  shouldEnableAnalytics,
} from './analytics';

afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('analytics before_send scrubber', () => {
  it('strips query strings and fragments from URL and pathname properties', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_project_key', surface: 'staff' });
    const event: CaptureResult = {
      uuid: 'evt-1',
      event: '$pageview',
      properties: {
        token: 'phc_project_key',
        $current_url: 'https://payroll.shimizu-technology.com/invite?__clerk_ticket=secret_ticket_123#token=abc',
        $referrer: 'https://accounts.clerk.dev/sign-in?redirect_url=https://payroll.shimizu-technology.com/app#frag',
        $initial_referrer: 'https://payroll.shimizu-technology.com/login?email=ada@example.com#hash',
        $pathname: '/invite?__clerk_ticket=secret#hash',
        $initial_current_url: 'https://payroll.shimizu-technology.com/app?foo=bar#baz',
        $initial_pathname: '/app?foo=bar#baz',
        $prev_pageview_pathname: '/companies/42/employees/99?tab=pay#section',
        $external_click_url: 'https://example.com/reset?token=secret#frag',
        $elements: [
          {
            tag_name: 'a',
            attr__href: 'https://payroll.shimizu-technology.com/companies/42/employees/99?__clerk_ticket=abc#sec',
          },
        ],
        $elements_chain:
          'a:attr__href="https://payroll.shimizu-technology.com/companies/42/employees/99?secret=1#top"',
      },
      $set_once: {
        $initial_current_url: 'https://payroll.shimizu-technology.com/companies/42/employees/99?a=1#b',
        $initial_referrer: 'https://payroll.shimizu-technology.com/login?ticket=xyz#frag',
      },
    };

    const scrubbed = beforeSend(event);
    expect(scrubbed).not.toBeNull();
    expect(scrubbed?.properties.token).toBe('phc_project_key');
    expect(scrubbed?.properties.$current_url).toBe('https://payroll.shimizu-technology.com/invite');
    expect(scrubbed?.properties.$referrer).toBe('https://accounts.clerk.dev/sign-in');
    expect(scrubbed?.properties.$initial_referrer).toBe('https://payroll.shimizu-technology.com/login');
    expect(scrubbed?.properties.$pathname).toBe('/invite');
    expect(scrubbed?.properties.$initial_current_url).toBe('https://payroll.shimizu-technology.com/app');
    expect(scrubbed?.properties.$initial_pathname).toBe('/app');
    expect(scrubbed?.properties.$prev_pageview_pathname).toBe('/companies/:id/employees/:id');
    expect(scrubbed?.properties.$external_click_url).toBe('https://example.com/reset');
    expect(scrubbed?.properties.$elements).toEqual([
      {
        tag_name: 'a',
        attr__href: 'https://payroll.shimizu-technology.com/companies/:id/employees/:id',
      },
    ]);
    expect(scrubbed?.properties.$elements_chain).toBe(
      'a:attr__href="https://payroll.shimizu-technology.com/companies/:id/employees/:id"',
    );
    expect(scrubbed?.$set_once).toEqual({
      $initial_current_url: 'https://payroll.shimizu-technology.com/companies/:id/employees/:id',
      $initial_referrer: 'https://payroll.shimizu-technology.com/login',
    });
  });

  it('masks numeric, UUID, hex, prefixed, JWT, email, and token-like path segments while keeping route names', () => {
    expect(scrubPathname('/companies/42/employees/9876543210/edit')).toBe('/companies/:id/employees/:id/edit');
    expect(scrubPathname('/pay-runs/550e8400-e29b-41d4-a716-446655440000/payroll-items/123')).toBe(
      '/pay-runs/:id/payroll-items/:id',
    );
    expect(scrubPathname('/invite/a1b2c3d4e5f6a7b8c9d0e1f2')).toBe('/invite/:id');
    expect(scrubPathname('/users/user_2abcDEF12345678')).toBe('/users/:id');
    expect(scrubPathname('/callback/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig12345')).toBe(
      '/callback/:id',
    );
    expect(scrubPathname('/invite/LongOpaqueTokenValue12345')).toBe('/invite/:id');
    expect(scrubPathname('/users/ada@example.com/profile')).toBe('/users/:id/profile');

    // Readable kebab-case static routes stay intact.
    expect(scrubPathname('/app/aire-account-connection')).toBe('/app/aire-account-connection');
    expect(scrubPathname('/companies/42/contact-changes-to-confirm')).toBe('/companies/:id/contact-changes-to-confirm');
    expect(scrubPathname('/companies/42/prior-provider-history')).toBe('/companies/:id/prior-provider-history');
    expect(scrubPathname('/pay-periods/12/form-500')).toBe('/pay-periods/:id/form-500');
    expect(scrubUrl('$direct')).toBe('$direct');
  });

  it('drops every sensitive property key across top-level, nested, $set, and $set_once while preserving safe keys', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    const event: CaptureResult = {
      uuid: 'evt-2',
      event: 'custom_event',
      properties: {
        token: 'phc_live_key',
        ssn: '123-45-6789',
        ssn_last4: '6789',
        tax_id: '98-7654321',
        taxId: '98-7654321',
        bank: 'First Hawaiian',
        bankAccount: '000123456',
        routing: '121000358',
        routingNumber: '121000358',
        account: 'acct_123',
        account_number: '99887766',
        password: 'secret',
        password_hash: 'hash',
        access_token: 'tok_secret',
        inviteToken: 'inv_secret',
        email: 'ada@example.com',
        userEmail: 'ada@example.com',
        phone: '671-555-0100',
        phoneNumber: '671-555-0100',
        dob: '1990-01-02',
        date_of_birth: '1990-01-02',
        birth_date: '1990-01-02',
        salary: 95000,
        annualSalary: 95000,
        wage: 25.5,
        hourly_wage: 25.5,
        rate: 25.5,
        hourlyRate: 25.5,
        amount: 1234.56,
        gross_amount: 1234.56,
        nested: {
          token: 'not-the-project-key',
          employeeEmail: 'nested@example.com',
          safe_flag: true,
        },
        role: 'admin',
        surface: 'staff',
        report_type: 'payroll_register',
        generated_at: '2026-11-25',
      },
      $set: {
        role: 'admin',
        email: 'ada@example.com',
        phone: '671-555-0100',
      },
      $set_once: {
        token: 'should-drop-in-set-once',
        surface: 'staff',
      },
    };

    const scrubbed = beforeSend(event);
    expect(scrubbed?.properties).toEqual({
      token: 'phc_live_key',
      nested: { safe_flag: true },
      role: 'admin',
      surface: 'staff',
      report_type: 'payroll_register',
      generated_at: '2026-11-25',
    });
    expect(scrubbed?.$set).toEqual({ role: 'admin' });
    expect(scrubbed?.$set_once).toEqual({ surface: 'staff' });

    // Non-project top-level token is still dropped.
    const foreignTokenScrubbed = beforeSend({
      uuid: 'evt-3',
      event: 'custom_event',
      properties: { token: 'arbitrary-invite-token', surface: 'staff' },
    });
    expect(foreignTokenScrubbed?.properties).toEqual({ surface: 'staff' });
    expect(isSensitivePropertyKey('generated_at')).toBe(false);
    expect(isSensitivePropertyKey('pay_rate')).toBe(true);
    expect(isSensitivePropertyKey('tax_id')).toBe(true);
  });

  it('redacts employer tenant hosts, page titles, and pay/employer/employee identifiers on the employee surface', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'employee' });
    const scrubbed = beforeSend({
      uuid: 'evt-emp',
      event: '$pageview',
      properties: {
        token: 'phc_live_key',
        $current_url: 'https://mosas.shimizu-technology.com/pay/stmt-9?from=all&year=2026#top',
        $pathname: '/pay/stmt-9',
        $host: 'mosas.shimizu-technology.com',
        $referrer: 'https://mosas.shimizu-technology.com/activate#token=secret',
        $referring_domain: 'mosas.shimizu-technology.com',
        title: "Pay stubs · MoSa's",
        company_id: 42,
        company_name: "MoSa's",
        employee_id: 7,
        link_id: 99,
        statement_id: 'stmt-9',
        surface: 'employee',
      },
    });

    expect(scrubbed?.properties).toEqual({
      token: 'phc_live_key',
      $current_url: 'https://tenant.shimizu-technology.com/pay/:id',
      $pathname: '/pay/:id',
      $host: 'tenant.shimizu-technology.com',
      $referrer: 'https://tenant.shimizu-technology.com/activate',
      $referring_domain: 'tenant.shimizu-technology.com',
      surface: 'employee',
    });
    // /pay/all remains readable as a static route.
    expect(scrubPathname('/pay/all', { surface: 'employee' })).toBe('/pay/all');
  });
});

describe('analytics identify and pseudonymous ids', () => {
  it('computes a stable, non-reversible salted SHA-256 pseudonymous user id', () => {
    const expected =
      'usr_' +
      createHash('sha256')
        .update('test-salt:42')
        .digest('hex')
        .slice(0, 32);

    expect(pseudonymousUserId(42, 'test-salt')).toBe(expected);
    expect(pseudonymousUserId('42', 'test-salt')).toBe(expected);
    expect(pseudonymousUserId(42, 'other-salt')).not.toBe(expected);
    expect(pseudonymousUserId(42, 'test-salt')).not.toContain('42');

    const defaultExpected =
      'usr_' +
      createHash('sha256')
        .update(`${DEFAULT_POSTHOG_ID_SALT}:99`)
        .digest('hex')
        .slice(0, 32);
    expect(pseudonymousUserId(99, '')).toBe(defaultExpected);
  });

  it('sends only pseudonymous id, role, and surface on staff identify — never email, name, or company_id', () => {
    const identify = vi.fn();
    identifyUser({ identify }, { userId: 42, role: 'accountant', surface: 'staff' }, 'build-salt');

    expect(identify).toHaveBeenCalledTimes(1);
    const [distinctId, props] = identify.mock.calls[0] as [string, Record<string, unknown>];
    expect(distinctId).toBe(pseudonymousUserId(42, 'build-salt'));
    expect(distinctId).not.toBe('42');
    expect(props).toEqual({ role: 'accountant', surface: 'staff' });
    expect(props).not.toHaveProperty('email');
    expect(props).not.toHaveProperty('name');
    expect(props).not.toHaveProperty('company_id');
    expect(props).not.toHaveProperty('company_name');
  });

  it('never identifies users on the employee surface', () => {
    const identify = vi.fn();
    identifyUser({ identify }, { userId: 42, role: 'employee', surface: 'employee' }, 'build-salt');
    expect(identify).not.toHaveBeenCalled();
  });

  it('captures scrubbed page views without query strings or fragments', () => {
    const capture = vi.fn();
    capturePageView({ capture }, '/companies/42/employees/123?__clerk_ticket=secret#hash', 'staff');
    expect(capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/companies/:id/employees/:id`,
      $pathname: '/companies/:id/employees/:id',
      surface: 'staff',
    });
  });
});

describe('analytics initialization gating and config', () => {
  const enabledEnv = {
    VITE_PUBLIC_POSTHOG_ENABLED: 'true',
    VITE_PUBLIC_POSTHOG_KEY: 'phc_synthetic_test_key',
    VITE_DEPLOYMENT_ENV: 'production',
    DEV: false,
  };

  it('does not initialize when disabled, missing key, placeholder key, staging, support, DNT, or GPC', () => {
    const init = vi.fn();

    expect(initAnalytics({ env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_ENABLED: 'false' }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_ENABLED: undefined }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_KEY: '' }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_KEY: 'YOUR_POSTHOG_KEY' }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: { ...enabledEnv, VITE_DEPLOYMENT_ENV: 'staging' }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: enabledEnv, isStagingEnv: true, client: { init } })).toBe(false);
    expect(initAnalytics({ env: enabledEnv, hasSupportToken: true, client: { init } })).toBe(false);
    expect(initAnalytics({ env: enabledEnv, navigatorObj: { doNotTrack: '1' }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: enabledEnv, navigatorObj: { globalPrivacyControl: true }, client: { init } })).toBe(false);
    expect(initAnalytics({ env: enabledEnv, windowObj: { doNotTrack: '1' }, client: { init } })).toBe(false);

    expect(init).not.toHaveBeenCalled();
    expect(hasPrivacyOptOutSignal({ doNotTrack: '1' }, {})).toBe(true);
    expect(hasPrivacyOptOutSignal({ globalPrivacyControl: true }, {})).toBe(true);
    expect(hasPrivacyOptOutSignal({ doNotTrack: '0', globalPrivacyControl: false }, {})).toBe(false);
  });

  it('initializes with strict privacy options when explicitly enabled', () => {
    const init = vi.fn();
    expect(shouldEnableAnalytics({ env: enabledEnv, isStagingEnv: false, hasSupportToken: false, navigatorObj: {}, windowObj: {} })).toBe(true);

    const started = initAnalytics({
      env: enabledEnv,
      isStagingEnv: false,
      hasSupportToken: false,
      navigatorObj: {},
      windowObj: {},
      surface: 'staff',
      client: { init },
    });

    expect(started).toBe(true);
    expect(init).toHaveBeenCalledTimes(1);
    const [key, config] = init.mock.calls[0];
    expect(key).toBe('phc_synthetic_test_key');
    expect(config).toMatchObject({
      api_host: DEFAULT_POSTHOG_HOST,
      person_profiles: 'identified_only',
      capture_pageview: false,
      capture_pageleave: true,
      disable_session_recording: true,
      disable_surveys: true,
      mask_all_text: true,
      mask_all_element_attributes: true,
      ip: false,
      persistence: 'localStorage+cookie',
      respect_dnt: true,
      save_campaign_params: false,
    });
    expect(config.autocapture).toEqual({
      css_selector_ignorelist: expect.arrayContaining(['input', 'textarea', 'select', '[data-ph-no-capture]']),
    });
    expect(typeof config.before_send).toBe('function');
  });

  it('uses custom api_host from env when provided', () => {
    const config = buildPostHogConfig({
      env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_HOST: 'https://eu.i.posthog.com' },
      surface: 'employee',
    });
    expect(config.api_host).toBe('https://eu.i.posthog.com');
  });

  it('does not initialize PostHogProvider during a support/view-as session', async () => {
    vi.resetModules();
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_PUBLIC_POSTHOG_ENABLED', 'true');
    vi.stubEnv('VITE_PUBLIC_POSTHOG_KEY', 'phc_synthetic_test_key');
    window.sessionStorage.setItem('payroll-support-view', 'a'.repeat(43));

    const initMock = vi.fn();
    vi.doMock('posthog-js', () => ({ default: { init: initMock, capture: vi.fn(), reset: vi.fn() } }));

    try {
      const { PostHogProvider, PostHogPageView } = await import('../providers/PostHogProvider');
      render(
        <PostHogProvider surface="employee">
          <MemoryRouter initialEntries={['/pay/42']}>
            <PostHogPageView surface="employee" />
          </MemoryRouter>
        </PostHogProvider>,
      );
      expect(initMock).not.toHaveBeenCalled();
    } finally {
      window.sessionStorage.removeItem('payroll-support-view');
      vi.doUnmock('posthog-js');
      vi.resetModules();
    }
  });
});
