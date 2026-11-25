// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { PostHog, type CaptureResult } from 'posthog-js';
import {
  DEFAULT_POSTHOG_HOST,
  DROPPED_EVENT_TYPES,
  analytics,
  buildPostHogConfig,
  capturePageView,
  createBeforeSend,
  hasPrivacyOptOutSignal,
  initAnalytics,
  registerAnalyticsContext,
  resetAnalytics,
  scrubPathname,
  scrubUrl,
  shouldEnableAnalytics,
} from './analytics';

afterEach(() => {
  cleanup();
  window.localStorage.clear();
  window.sessionStorage.clear();
  window.history.replaceState({}, '', '/');
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('analytics strict allowlist before_send', () => {
  it('rebuilds properties from the explicit allowlist and drops every sensitive, URL/referrer, $set, $set_once, and free-text key', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    const event: CaptureResult = {
      uuid: 'evt-allowlist',
      event: '$pageview',
      timestamp: new Date('2026-11-26T00:00:00Z'),
      properties: {
        // Allowed keys
        token: 'phc_live_key',
        $pathname: '/companies/42/employees/99?__clerk_ticket=secret_ticket&__clerk_status=sign_up#/secret/123',
        $current_url:
          'https://payroll.shimizu-technology.com/companies/42/employees/99?__clerk_ticket=secret_ticket&__clerk_status=sign_up#/secret/123',
        $host: 'payroll.shimizu-technology.com',
        $browser: 'Chrome',
        $browser_version: 130,
        $os: 'Mac OS X',
        $device_type: 'Desktop',
        $screen_height: 900,
        $screen_width: 1440,
        $viewport_height: 820,
        $viewport_width: 1280,
        $lib: 'web',
        $lib_version: '1.399.2',
        $insert_id: 'ins-123',
        $time: 1764115200,
        distinct_id: 'anon-device-uuid-1',
        $session_id: 'sess-uuid-1',
        $window_id: 'win-uuid-1',
        $process_person_profile: false,
        role: 'accountant',
        surface: 'staff',

        // Session-entry, initial, referrer, and other URL keys — MUST BE DROPPED
        $session_entry_url: 'https://payroll.shimizu-technology.com/invite?__clerk_ticket=leaked#/frag',
        $session_entry_referrer: 'https://accounts.clerk.dev/sign-in?__clerk_ticket=leaked#frag',
        $session_entry_referring_domain: 'accounts.clerk.dev',
        $session_entry_host: 'payroll.shimizu-technology.com',
        $session_entry_pathname: '/invite?__clerk_ticket=leaked',
        $initial_current_url: 'https://payroll.shimizu-technology.com/invite?__clerk_ticket=leaked#/frag',
        $initial_referrer: 'https://accounts.clerk.dev/sign-in?email=ada@example.com',
        $initial_referring_domain: 'accounts.clerk.dev',
        $initial_pathname: '/invite',
        $referrer: 'https://accounts.clerk.dev/sign-in?redirect_url=secret',
        $referring_domain: 'accounts.clerk.dev',
        $prev_pageview_pathname: '/companies/42/employees/99',
        $external_click_url: 'blob:https://payroll.shimizu-technology.com/550e8400-e29b-41d4-a716-446655440000',

        // Sensitive PII / payroll / financial / identifier / free-text keys — MUST BE DROPPED
        ssn: '123-45-6789',
        ssn_last4: '6789',
        tax_id: '98-7654321',
        taxId: '98-7654321',
        bank_account: '000123456',
        routing_number: '121000358',
        account_number: '99887766',
        password: 'secret',
        access_token: 'tok_secret',
        email: 'ada@example.com',
        name: 'Ada Lovelace',
        phone: '671-555-0100',
        dob: '1990-01-02',
        salary: 95000,
        hourly_wage: 25.5,
        hourlyRate: 25.5,
        gross_amount: 1234.56,
        company_id: 42,
        company_name: "MoSa's",
        employee_id: 99,
        user_id: 7,
        link_id: 12,
        statement_id: 'stmt-9',
        pay_period_id: 55,
        title: 'Payroll · Ada Lovelace',
        $el_text: 'Ada Lovelace — $2,500.00',
        $selected_content: '123-45-6789',
        $raw_user_agent: 'Mozilla/5.0 ...',
        $ip: '203.0.113.5',
        $geoip_city_name: 'Hagatna',
        $set: { email: 'ada@example.com' },
        $set_once: { $initial_current_url: 'https://payroll.shimizu-technology.com/?__clerk_ticket=secret' },
        arbitrary_free_text: 'employee note with SSN 123-45-6789',
      },
      $set: {
        email: 'ada@example.com',
        role: 'accountant',
      },
      $set_once: {
        $initial_current_url: 'https://payroll.shimizu-technology.com/?__clerk_ticket=secret',
        $initial_referrer: 'https://accounts.clerk.dev/',
      },
    };

    const scrubbed = beforeSend(event);
    expect(scrubbed).toEqual({
      uuid: 'evt-allowlist',
      event: '$pageview',
      timestamp: new Date('2026-11-26T00:00:00Z'),
      properties: {
        token: 'phc_live_key',
        $pathname: '/companies/:id/employees/:id',
        $current_url: 'https://payroll.shimizu-technology.com/companies/:id/employees/:id',
        $host: 'payroll.shimizu-technology.com',
        $browser: 'Chrome',
        $browser_version: 130,
        $os: 'Mac OS X',
        $device_type: 'Desktop',
        $screen_height: 900,
        $screen_width: 1440,
        $viewport_height: 820,
        $viewport_width: 1280,
        $lib: 'web',
        $lib_version: '1.399.2',
        $insert_id: 'ins-123',
        $time: 1764115200,
        distinct_id: 'anon-device-uuid-1',
        $session_id: 'sess-uuid-1',
        $window_id: 'win-uuid-1',
        $process_person_profile: false,
        role: 'accountant',
        surface: 'staff',
      },
    });
    expect(scrubbed).not.toHaveProperty('$set');
    expect(scrubbed).not.toHaveProperty('$set_once');

    // Non-project token and $process_person_profile: true are dropped.
    const foreignTokenScrubbed = beforeSend({
      uuid: 'evt-foreign-token',
      event: 'company_switched',
      properties: {
        token: 'not-the-project-key',
        $process_person_profile: true,
        surface: 'staff',
      },
    });
    expect(foreignTokenScrubbed?.properties).toEqual({ surface: 'staff' });
  });

  it('scrubs URLs with __clerk_ticket, __clerk_status, fragments, IDs, tenant hosts, and drops blob: URLs', () => {
    expect(
      scrubUrl('https://payroll.shimizu-technology.com/invite?__clerk_ticket=tok_secret&__clerk_status=sign_up#/step/2'),
    ).toBe('https://payroll.shimizu-technology.com/invite');
    expect(
      scrubUrl('https://payroll.shimizu-technology.com/#/companies/42/employees/99?__clerk_ticket=secret'),
    ).toBe('https://payroll.shimizu-technology.com/');
    expect(
      scrubUrl('https://user:pass@payroll.shimizu-technology.com/companies/42/employees/9876543210/edit?x=1#frag'),
    ).toBe('https://payroll.shimizu-technology.com/companies/:id/employees/:id/edit');
    expect(
      scrubUrl('https://mosas.shimizu-technology.com/pay/stmt-9?__clerk_ticket=abc#/details', { surface: 'employee' }),
    ).toBe('https://tenant.shimizu-technology.com/pay/:id');
    expect(scrubUrl('blob:https://mosas.shimizu-technology.com/550e8400-e29b-41d4-a716-446655440000')).toBeUndefined();
    expect(scrubUrl('javascript:alert(1)')).toBeUndefined();

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
    expect(scrubPathname('/app/aire-account-connection')).toBe('/app/aire-account-connection');
    expect(scrubPathname('/pay/all', { surface: 'employee' })).toBe('/pay/all');
    expect(scrubPathname('/pay/stmt-9?year=2026#/top', { surface: 'employee' })).toBe('/pay/:id');
  });

  it('keeps only element tag names and explicit data-ph-name on autocapture and strips href (including blob:) and $el_text', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'employee' });
    const scrubbed = beforeSend({
      uuid: 'evt-auto-1',
      event: '$autocapture',
      properties: {
        token: 'phc_live_key',
        $current_url: 'https://mosas.shimizu-technology.com/pay/stmt-9?year=2026#download',
        $pathname: '/pay/stmt-9',
        $host: 'mosas.shimizu-technology.com',
        $el_text: 'Download pay stub for Ada Lovelace ($1,450.00)',
        $external_click_url: 'blob:https://mosas.shimizu-technology.com/550e8400-e29b-41d4-a716-446655440000',
        $elements: [
          {
            tag_name: 'A',
            $el_text: 'Download PDF',
            attr__href: 'blob:https://mosas.shimizu-technology.com/550e8400-e29b-41d4-a716-446655440000',
            attr__id: 'download-stmt-9',
            attr__class: 'emp-btn secret-class',
            'attr__aria-label': 'Download pay stub for Ada Lovelace',
            'attr__data-ph-name': 'download-pay-stub',
          },
          {
            tag_name: 'div',
            attr__id: 'employer-mosas',
            'attr__data-ph-name': 'https://evil.example/leak',
          },
        ],
        $elements_chain:
          'a.emp-btn:attr__data-ph-name="download-pay-stub"attr__href="blob:https://mosas.shimizu-technology.com/abc"text="Ada Lovelace";div:attr_id="employer-mosas"',
        role: 'employee',
        surface: 'employee',
      },
    });

    expect(scrubbed?.properties).toEqual({
      token: 'phc_live_key',
      $current_url: 'https://tenant.shimizu-technology.com/pay/:id',
      $pathname: '/pay/:id',
      $host: 'tenant.shimizu-technology.com',
      surface: 'employee',
      $elements: [
        { tag_name: 'a', 'attr__data-ph-name': 'download-pay-stub' },
        { tag_name: 'div' },
      ],
      $elements_chain: 'a:attr__data-ph-name="download-pay-stub";div:',
    });
    expect(JSON.stringify(scrubbed)).not.toContain('blob:');
    expect(JSON.stringify(scrubbed)).not.toContain('Ada Lovelace');
    expect(JSON.stringify(scrubbed)).not.toContain('mosas');
    expect(JSON.stringify(scrubbed)).not.toContain('attr__href');
    expect(JSON.stringify(scrubbed)).not.toContain('role');

    // Chain-only autocapture events (when $elements is omitted) are also strictly scrubbed.
    const chainOnly = beforeSend({
      uuid: 'evt-auto-2',
      event: '$autocapture',
      properties: {
        token: 'phc_live_key',
        $elements_chain:
          'button.primary:attr__data-ph-name="submit-run"href="blob:https://example.test/123"text="Approve $50,000";section.payroll:attr_id="company-42"',
        surface: 'employee',
      },
    });
    expect(chainOnly?.properties.$elements_chain).toBe('button:attr__data-ph-name="submit-run";section:');
    expect(JSON.stringify(chainOnly)).not.toContain('blob:');
    expect(JSON.stringify(chainOnly)).not.toContain('50,000');
    expect(JSON.stringify(chainOnly)).not.toContain('company-42');
  });

  it('drops $exception, $web_vitals, $identify, $set, and other blocked event types entirely', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    for (const eventName of DROPPED_EVENT_TYPES) {
      expect(
        beforeSend({
          uuid: `evt-${eventName}`,
          event: eventName,
          properties: {
            token: 'phc_live_key',
            $exception_list: [{ value: 'SSN 123-45-6789 failed validation' }],
            surface: 'staff',
          },
        }),
      ).toBeNull();
    }
    expect(DROPPED_EVENT_TYPES.has('$exception')).toBe(true);
    expect(DROPPED_EVENT_TYPES.has('$web_vitals')).toBe(true);
    expect(DROPPED_EVENT_TYPES.has('$identify')).toBe(true);
  });
});

describe('analytics SDK runtime traffic & privacy guarantees (real PostHog 1.399.2)', () => {
  it('sends zero requests to /flags, /decide, /array/, or external scripts, persists no initial person URLs, and only sends allowlisted keys', () => {
    window.history.replaceState(
      {},
      '',
      '/invite?__clerk_ticket=secret_clerk_ticket&__clerk_status=sign_up#/companies/42/secret',
    );

    const requestUrls: string[] = [];
    const fetchSpy = vi.fn<typeof fetch>(async (input) => {
      requestUrls.push(String(input));
      return new Response(JSON.stringify({ status: 1 }), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchSpy);

    const xhrUrls: string[] = [];
    const originalXhrOpen = XMLHttpRequest.prototype.open;
    vi.spyOn(XMLHttpRequest.prototype, 'open').mockImplementation(function (
      this: XMLHttpRequest,
      method: string,
      url: string | URL,
      ...rest: unknown[]
    ) {
      xhrUrls.push(String(url));
      return originalXhrOpen.call(this, method, url, ...(rest as [boolean, string?, string?]));
    });
    vi.spyOn(XMLHttpRequest.prototype, 'send').mockImplementation(() => undefined);

    const beaconUrls: string[] = [];
    Object.defineProperty(navigator, 'sendBeacon', {
      configurable: true,
      value: vi.fn((url: string) => {
        beaconUrls.push(url);
        return true;
      }),
    });

    const createdScriptSrcs: string[] = [];
    const origCreateElement = document.createElement.bind(document);
    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string, options?: ElementCreationOptions) => {
      const el = origCreateElement(tagName, options);
      if (tagName.toLowerCase() === 'script') {
        const origSetAttr = el.setAttribute.bind(el);
        el.setAttribute = (name: string, value: string) => {
          if (name === 'src') createdScriptSrcs.push(value);
          return origSetAttr(name, value);
        };
        Object.defineProperty(el, 'src', {
          set(val: string) {
            createdScriptSrcs.push(val);
          },
          get() {
            return '';
          },
        });
      }
      return el;
    }) as typeof document.createElement);

    const capturedPayloads: CaptureResult[] = [];
    const env = {
      VITE_PUBLIC_POSTHOG_ENABLED: 'true',
      VITE_PUBLIC_POSTHOG_KEY: 'phc_real_sdk_test_key',
      VITE_DEPLOYMENT_ENV: 'production',
      DEV: false,
    };

    const instance = new PostHog();
    const baseConfig = buildPostHogConfig({ env, surface: 'staff' });
    const origBeforeSend = baseConfig.before_send as (event: CaptureResult | null) => CaptureResult | null;

    instance.init('phc_real_sdk_test_key', {
      ...baseConfig,
      name: `ph_test_${Date.now()}`,
      request_batching: false,
      before_send: (event) => {
        const result = origBeforeSend(event);
        if (result) capturedPayloads.push(result);
        return result;
      },
    });

    // Trigger pageview, custom event, and explicit reloadFeatureFlags (must stay disabled).
    capturePageView(instance, window.location.pathname + window.location.search + window.location.hash, 'staff');
    instance.capture('$exception', { $exception_message: 'SSN 123-45-6789' });
    instance.capture('$web_vitals', { $web_vitals_LCP_value: 1200 });
    instance.reloadFeatureFlags();

    const allUrls = [...requestUrls, ...xhrUrls, ...beaconUrls, ...createdScriptSrcs];
    for (const url of allUrls) {
      expect(url).not.toMatch(/\/flags\b|\/decide\b|\/array\/|us-assets\.i\.posthog\.com/i);
    }
    expect(createdScriptSrcs).toEqual([]);

    // No raw Clerk ticket/status values or initial person info persisted in localStorage.
    for (let i = 0; i < window.localStorage.length; i += 1) {
      const storageKey = window.localStorage.key(i);
      const storageVal = storageKey ? window.localStorage.getItem(storageKey) ?? '' : '';
      expect(storageVal).not.toContain('secret_clerk_ticket');
      expect(storageVal).not.toContain('sign_up');
      expect(storageVal).not.toContain('/companies/42/secret');
      expect(storageVal).not.toContain('$initial_person_info');
      expect(storageVal).not.toContain('$initial_referrer');
    }

    // Real SDK produced the $pageview (not dropped by PostHog's required `token` check)
    // and dropped $exception and $web_vitals.
    expect(capturedPayloads.map((e) => e.event)).toEqual(['$pageview']);
    const payload = capturedPayloads[0];
    expect(payload.properties.$pathname).toBe('/invite');
    expect(payload.properties.$current_url).toBe(`${window.location.origin}/invite`);
    expect(payload.properties.surface).toBe('staff');
    expect(payload.properties.token).toBe('phc_real_sdk_test_key');
    expect(payload.properties).not.toHaveProperty('$session_entry_url');
    expect(payload.properties).not.toHaveProperty('$session_entry_referrer');
    expect(payload.properties).not.toHaveProperty('$initial_current_url');
    expect(payload.properties).not.toHaveProperty('$initial_referrer');
    expect(payload.properties).not.toHaveProperty('$referrer');
    expect(payload).not.toHaveProperty('$set');
    expect(payload).not.toHaveProperty('$set_once');
    expect(JSON.stringify(payload)).not.toContain('__clerk_ticket');
    expect(JSON.stringify(payload)).not.toContain('__clerk_status');
    expect(JSON.stringify(payload)).not.toContain('/companies/42/secret');
  });
});

describe('analytics anonymous device context, reset, and no-identify policy', () => {
  it('registers only role and surface as super properties and never calls identify', () => {
    const client = {
      register: vi.fn(),
      unregister: vi.fn(),
      identify: vi.fn(),
      reset: vi.fn(),
    };

    registerAnalyticsContext(client, { surface: 'staff', role: 'accountant' });
    expect(client.register).toHaveBeenCalledWith({ surface: 'staff', role: 'accountant' });
    expect(client.identify).not.toHaveBeenCalled();

    // Employee surface never registers a role.
    client.register.mockClear();
    registerAnalyticsContext(client, { surface: 'employee', role: 'employee' });
    expect(client.register).toHaveBeenCalledWith({ surface: 'employee' });
    expect(client.unregister).toHaveBeenCalledWith('role');
    expect(client.identify).not.toHaveBeenCalled();
  });

  it('resets anonymous device/session id on sign-out and on company/employer switch without sending company_id', () => {
    const client = {
      reset: vi.fn(),
      register: vi.fn(),
      unregister: vi.fn(),
    };

    registerAnalyticsContext(client, { surface: 'staff', role: 'admin' });
    client.register.mockClear();

    // Company switch keeps role and surface after reset.
    resetAnalytics(client, { surface: 'staff', keepRole: true });
    expect(client.reset).toHaveBeenCalledTimes(1);
    expect(client.register).toHaveBeenCalledWith({ surface: 'staff', role: 'admin' });

    // Sign-out clears role after reset.
    client.reset.mockClear();
    client.register.mockClear();
    resetAnalytics(client, { surface: 'staff', keepRole: false });
    expect(client.reset).toHaveBeenCalledTimes(1);
    expect(client.register).toHaveBeenCalledWith({ surface: 'staff' });
    expect(client.unregister).toHaveBeenCalledWith('role');

    // analytics.companySwitch takes no companyId argument.
    expect(analytics.companySwitch.length).toBe(0);
  });

  it('captures scrubbed page views without query strings or fragments', () => {
    const capture = vi.fn();
    capturePageView({ capture }, '/companies/42/employees/123?__clerk_ticket=secret#/hash', 'staff');
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

  it('initializes with strict privacy options (no flags, no remote config, no exceptions/performance/heatmaps/dead clicks, no referrer/campaign persistence)', () => {
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
      person_profiles: 'never',
      capture_pageview: false,
      capture_pageleave: true,
      capture_exceptions: false,
      capture_performance: false,
      capture_dead_clicks: false,
      capture_heatmaps: false,
      enable_heatmaps: false,
      disable_session_recording: true,
      disable_surveys: true,
      disable_surveys_automatic_display: true,
      disable_product_tours: true,
      disable_conversations: true,
      disable_web_experiments: true,
      disable_external_dependency_loading: true,
      disable_capture_url_hashes: true,
      disable_scroll_properties: true,
      opt_in_site_apps: false,
      advanced_disable_flags: true,
      advanced_disable_feature_flags: true,
      advanced_disable_feature_flags_on_first_load: true,
      advanced_disable_toolbar_metrics: true,
      remote_config_refresh_interval_ms: 0,
      save_referrer: false,
      save_campaign_params: false,
      mask_all_text: true,
      mask_all_element_attributes: true,
      mask_personal_data_properties: true,
      ip: false,
      persistence: 'localStorage+cookie',
      respect_dnt: true,
    });
    expect(config.autocapture).toEqual({
      css_selector_ignorelist: expect.arrayContaining(['input', 'textarea', 'select', '[data-ph-no-capture]']),
    });
    expect(typeof config.before_send).toBe('function');
    expect(typeof config.get_current_url).toBe('function');
    expect(
      config.get_current_url?.('https://payroll.shimizu-technology.com/companies/42?__clerk_ticket=abc#/frag'),
    ).toBe('https://payroll.shimizu-technology.com/companies/:id');
  });

  it('uses EU PostHog api_host from env when provided', () => {
    const config = buildPostHogConfig({
      env: { ...enabledEnv, VITE_PUBLIC_POSTHOG_HOST: 'https://eu.i.posthog.com' },
      surface: 'employee',
    });
    expect(config.api_host).toBe('https://eu.i.posthog.com');
  });

  it('does not initialize PostHogProvider when disabled, in staging, or during a support/view-as session', async () => {
    const scenarios: Array<{ label: string; env: Record<string, string>; supportSession?: boolean }> = [
      {
        label: 'disabled',
        env: {
          VITE_DEPLOYMENT_ENV: 'production',
          VITE_PUBLIC_POSTHOG_ENABLED: 'false',
          VITE_PUBLIC_POSTHOG_KEY: 'phc_synthetic_test_key',
        },
      },
      {
        label: 'staging',
        env: {
          VITE_DEPLOYMENT_ENV: 'staging',
          VITE_PUBLIC_POSTHOG_ENABLED: 'true',
          VITE_PUBLIC_POSTHOG_KEY: 'phc_synthetic_test_key',
        },
      },
      {
        label: 'support session',
        env: {
          VITE_DEPLOYMENT_ENV: 'production',
          VITE_PUBLIC_POSTHOG_ENABLED: 'true',
          VITE_PUBLIC_POSTHOG_KEY: 'phc_synthetic_test_key',
        },
        supportSession: true,
      },
    ];

    for (const scenario of scenarios) {
      vi.resetModules();
      vi.unstubAllEnvs();
      window.sessionStorage.removeItem('payroll-support-view');
      for (const [k, v] of Object.entries(scenario.env)) {
        vi.stubEnv(k, v);
      }
      if (scenario.supportSession) {
        window.sessionStorage.setItem('payroll-support-view', 'a'.repeat(43));
      }

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
        expect(initMock, `expected no init in scenario: ${scenario.label}`).not.toHaveBeenCalled();
      } finally {
        cleanup();
        window.sessionStorage.removeItem('payroll-support-view');
        vi.doUnmock('posthog-js');
        vi.resetModules();
      }
    }
  });
});
