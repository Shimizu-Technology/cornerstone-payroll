// @vitest-environment jsdom
import { cleanup, render } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { PostHog, type CaptureResult } from 'posthog-js';
import {
  ANALYTICS_PERSISTENCE_NAME,
  DEFAULT_POSTHOG_HOST,
  DROPPED_EVENT_TYPES,
  UNKNOWN_ROUTE_TEMPLATE,
  analytics,
  buildPostHogConfig,
  capturePageView,
  clearLegacyPostHogPersistence,
  createBeforeSend,
  hasPrivacyOptOutSignal,
  initAnalytics,
  isAnonymousDistinctId,
  legacyPostHogPersistenceKey,
  registerAnalyticsContext,
  resetAnalytics,
  resolveRouteTemplate,
  scrubPathname,
  scrubUrl,
  shouldEnableAnalytics,
} from './analytics';
import { EMPLOYEE_ROUTE_OBJECTS, STAFF_ROUTE_OBJECTS } from './analytics-routes';

const VALID_UUID_V7 = '01936a1b-7c4d-7e8f-9a1b-2c3d4e5f6a7b';

function clearDocumentCookies(): void {
  for (const cookie of document.cookie.split(';')) {
    const name = cookie.split('=', 1)[0]?.trim();
    if (name) {
      document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; max-age=0; path=/`;
    }
  }
}

afterEach(() => {
  cleanup();
  window.localStorage.clear();
  window.sessionStorage.clear();
  clearDocumentCookies();
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
        distinct_id: VALID_UUID_V7,
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
        $pathname: '/companies/:companyId/employees/:id',
        $current_url: 'https://payroll.shimizu-technology.com/companies/:companyId/employees/:id',
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
        distinct_id: VALID_UUID_V7,
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
        distinct_id: VALID_UUID_V7,
        token: 'not-the-project-key',
        $process_person_profile: true,
        surface: 'staff',
      },
    });
    expect(foreignTokenScrubbed?.properties).toEqual({
      distinct_id: VALID_UUID_V7,
      surface: 'staff',
    });
  });

  it('drops events with non-UUIDv7 distinct_id (such as legacy staff user IDs) and calls reset', () => {
    expect(isAnonymousDistinctId(VALID_UUID_V7)).toBe(true);
    expect(isAnonymousDistinctId('01936A1B-7C4D-7E8F-AB12-2C3D4E5F6A7B')).toBe(true);

    const invalidIds: unknown[] = [
      '42',
      '12345',
      'user_2abcDEF12345678',
      'ada@example.com',
      '550e8400-e29b-41d4-a716-446655440000', // UUIDv4, not UUIDv7
      '01936a1b-7c4d-7e8f-1a1b-2c3d4e5f6a7b', // invalid RFC 9562 variant nibble
      'anon-device-uuid-1',
      '',
      undefined,
      null,
      42,
    ];

    for (const badId of invalidIds) {
      expect(isAnonymousDistinctId(badId), `expected ${String(badId)} to be rejected`).toBe(false);
      const onInvalidDistinctId = vi.fn();
      const beforeSend = createBeforeSend({
        projectKey: 'phc_live_key',
        surface: 'staff',
        onInvalidDistinctId,
      });

      const result = beforeSend({
        uuid: 'evt-bad-id',
        event: '$pageview',
        properties: {
          token: 'phc_live_key',
          distinct_id: badId,
          $pathname: '/app',
          surface: 'staff',
        },
      });
      expect(result).toBeNull();
      expect(onInvalidDistinctId).toHaveBeenCalledTimes(1);
    }
  });

  it('resolves matched route templates for staff and employee surfaces, handles tricky short mixed-character IDs, and falls back to /unknown', () => {
    // Staff surface: tricky short mixed-character IDs that defeat heuristic redaction
    expect(resolveRouteTemplate('/companies/ab12/employees/x9', 'staff')).toBe(
      '/companies/:companyId/employees/:id',
    );
    expect(resolveRouteTemplate('/companies/c7/employees/k3m/taxes', 'staff')).toBe(
      '/companies/:companyId/employees/:id/:tab',
    );
    expect(resolveRouteTemplate('/companies/a1/employees/b2/edit', 'staff')).toBe(
      '/companies/:companyId/employees/:id/edit',
    );
    expect(resolveRouteTemplate('/companies/a1/employees/new', 'staff')).toBe(
      '/companies/:companyId/employees/new',
    );
    expect(resolveRouteTemplate('/companies/ab12/pay-runs/pr7', 'staff')).toBe(
      '/companies/:companyId/pay-runs/:id',
    );
    expect(resolveRouteTemplate('/companies/ab12/pay-runs/pr7/review', 'staff')).toBe(
      '/companies/:companyId/pay-runs/:id/:tab',
    );
    expect(resolveRouteTemplate('/companies/ab12/pay-runs/imported/q1', 'staff')).toBe(
      '/companies/:companyId/pay-runs/imported/:id',
    );
    expect(resolveRouteTemplate('/companies/ab12/pay-runs/pr7/payroll-items/i9x', 'staff')).toBe(
      '/companies/:companyId/pay-runs/:id/payroll-items/:payrollItemId',
    );
    expect(resolveRouteTemplate('/companies/ab12/payroll-submissions/q1-26', 'staff')).toBe(
      '/companies/:companyId/payroll-submissions/:ref',
    );
    expect(resolveRouteTemplate('/payroll-files/p4x', 'staff')).toBe('/payroll-files/:ref');
    expect(resolveRouteTemplate('/employees/Ada_1', 'staff')).toBe('/employees/:id');
    expect(resolveRouteTemplate('/pay-periods/pp2/form-500', 'staff')).toBe('/pay-periods/:id/form-500');
    expect(resolveRouteTemplate('/tools/invoices/billing-profiles/bp9/style', 'staff')).toBe(
      '/tools/invoices/billing-profiles/:profileId/style',
    );
    expect(resolveRouteTemplate('/settings/payroll-submissions/s7b', 'staff')).toBe(
      '/settings/payroll-submissions/:ref',
    );
    expect(resolveRouteTemplate('/app/aire-account-connection', 'staff')).toBe('/app/aire-account-connection');
    expect(resolveRouteTemplate('/', 'staff')).toBe('/');

    // Unmatched staff paths and layout-only parent routes return /unknown (never leaking arbitrary segments)
    expect(resolveRouteTemplate('/companies/ab12', 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/companies/ab12/secret-slug', 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/a1b2/c3d4', 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/users/ada@example.com/profile', 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/pay/stmt-9', 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);

    // Employee surface: tricky short mixed-character statement IDs vs static /pay/all
    expect(resolveRouteTemplate('/pay/x9', 'employee')).toBe('/pay/:statementId');
    expect(resolveRouteTemplate('/pay/a1b', 'employee')).toBe('/pay/:statementId');
    expect(resolveRouteTemplate('/pay/stmt-9?year=2026#/top', 'employee')).toBe('/pay/:statementId');
    expect(resolveRouteTemplate('/pay/all', 'employee')).toBe('/pay/all');
    expect(resolveRouteTemplate('/pay', 'employee')).toBe('/pay');
    expect(resolveRouteTemplate('/sign-up/done', 'employee')).toBe('/sign-up/done');
    expect(resolveRouteTemplate('/my-info', 'employee')).toBe('/my-info');
    expect(resolveRouteTemplate('/', 'employee')).toBe('/');

    // Unmatched employee paths return /unknown
    expect(resolveRouteTemplate('/pay/x9/extra', 'employee')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/companies/42/employees/99', 'employee')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate('/secret-k3m', 'employee')).toBe(UNKNOWN_ROUTE_TEMPLATE);

    // URL scrubbing combines origin (with employee tenant host redaction) + route template,
    // drops query strings, fragments, credentials, and non-HTTP(S) URLs.
    expect(
      scrubUrl('https://payroll.shimizu-technology.com/invite?__clerk_ticket=tok_secret&__clerk_status=sign_up#/step/2'),
    ).toBe('https://payroll.shimizu-technology.com/invite');
    expect(
      scrubUrl('https://payroll.shimizu-technology.com/#/companies/42/employees/99?__clerk_ticket=secret'),
    ).toBe('https://payroll.shimizu-technology.com/');
    expect(
      scrubUrl('https://user:pass@payroll.shimizu-technology.com/companies/ab12/employees/x9k2/edit?x=1#frag'),
    ).toBe('https://payroll.shimizu-technology.com/companies/:companyId/employees/:id/edit');
    expect(
      scrubUrl('https://payroll.shimizu-technology.com/not-a-real-route/a1b2?x=1#frag'),
    ).toBe('https://payroll.shimizu-technology.com/unknown');
    expect(
      scrubUrl('https://mosas.shimizu-technology.com/pay/x9k2?__clerk_ticket=abc#/details', { surface: 'employee' }),
    ).toBe('https://tenant.shimizu-technology.com/pay/:statementId');
    expect(
      scrubUrl('https://mosas.shimizu-technology.com/unknown-x9', { surface: 'employee' }),
    ).toBe('https://tenant.shimizu-technology.com/unknown');
    expect(scrubUrl('blob:https://mosas.shimizu-technology.com/550e8400-e29b-41d4-a716-446655440000')).toBeUndefined();
    expect(scrubUrl('javascript:alert(1)')).toBeUndefined();
    expect(scrubPathname('/companies/ab12/employees/x9')).toBe('/companies/:companyId/employees/:id');
    expect(scrubPathname('/pay/x9', { surface: 'employee' })).toBe('/pay/:statementId');
  });

  it('is idempotent for every declared staff and employee route template', () => {
    const collectTemplates = (
      routes: typeof STAFF_ROUTE_OBJECTS,
      prefix = '',
    ): string[] => {
      const templates: string[] = [];
      for (const route of routes) {
        const segment = (route.path ?? '').replace(/^\/+|\/+$/g, '');
        const full = segment ? `${prefix}/${segment}` : prefix || '/';
        if (route.children?.length) {
          templates.push(...collectTemplates(route.children, full));
        } else {
          templates.push(full);
        }
      }
      return templates;
    };

    for (const template of collectTemplates(STAFF_ROUTE_OBJECTS)) {
      expect(resolveRouteTemplate(template, 'staff')).toBe(template);
    }
    for (const template of collectTemplates(EMPLOYEE_ROUTE_OBJECTS)) {
      expect(resolveRouteTemplate(template, 'employee')).toBe(template);
    }
    expect(resolveRouteTemplate(UNKNOWN_ROUTE_TEMPLATE, 'staff')).toBe(UNKNOWN_ROUTE_TEMPLATE);
    expect(resolveRouteTemplate(UNKNOWN_ROUTE_TEMPLATE, 'employee')).toBe(UNKNOWN_ROUTE_TEMPLATE);
  });

  it('keeps only element tag names on autocapture and strips all attributes (including data-ph-name, href, blob:) and $el_text', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'employee' });
    const scrubbed = beforeSend({
      uuid: 'evt-auto-1',
      event: '$autocapture',
      properties: {
        token: 'phc_live_key',
        distinct_id: VALID_UUID_V7,
        $current_url: 'https://mosas.shimizu-technology.com/pay/x9k2?year=2026#download',
        $pathname: '/pay/x9k2',
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
      distinct_id: VALID_UUID_V7,
      $current_url: 'https://tenant.shimizu-technology.com/pay/:statementId',
      $pathname: '/pay/:statementId',
      $host: 'tenant.shimizu-technology.com',
      surface: 'employee',
      $elements: [{ tag_name: 'a' }, { tag_name: 'div' }],
      $elements_chain: 'a:;div:',
    });
    expect(JSON.stringify(scrubbed)).not.toContain('blob:');
    expect(JSON.stringify(scrubbed)).not.toContain('Ada Lovelace');
    expect(JSON.stringify(scrubbed)).not.toContain('mosas');
    expect(JSON.stringify(scrubbed)).not.toContain('attr__href');
    expect(JSON.stringify(scrubbed)).not.toContain('download-pay-stub');
    expect(JSON.stringify(scrubbed)).not.toContain('role');

    // Chain-only autocapture events (when $elements is omitted) are also strictly scrubbed to tag names.
    const chainOnly = beforeSend({
      uuid: 'evt-auto-2',
      event: '$autocapture',
      properties: {
        token: 'phc_live_key',
        distinct_id: VALID_UUID_V7,
        $elements_chain:
          'button.primary:attr__data-ph-name="submit-run"href="blob:https://example.test/123"text="Approve $50,000";section.payroll:attr_id="company-42"',
        surface: 'employee',
      },
    });
    expect(chainOnly?.properties.$elements_chain).toBe('button:;section:');
    expect(JSON.stringify(chainOnly)).not.toContain('blob:');
    expect(JSON.stringify(chainOnly)).not.toContain('50,000');
    expect(JSON.stringify(chainOnly)).not.toContain('company-42');
    expect(JSON.stringify(chainOnly)).not.toContain('submit-run');
  });

  it('drops $exception, $web_vitals, $identify, $set, and other required blocked event types independently of DROPPED_EVENT_TYPES', () => {
    const requiredBlockedEvents = [
      '$exception',
      '$web_vitals',
      '$identify',
      '$set',
      '$groupidentify',
      '$create_alias',
      '$dead_click',
      '$heatmap_data',
      '$snapshot',
      '$performance_event',
      '$feature_flag_called',
      'survey shown',
      'survey sent',
      'survey dismissed',
    ];
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    for (const eventName of requiredBlockedEvents) {
      expect(
        beforeSend({
          uuid: `evt-${eventName}`,
          event: eventName,
          properties: {
            token: 'phc_live_key',
            distinct_id: VALID_UUID_V7,
            $exception_list: [{ value: 'SSN 123-45-6789 failed validation' }],
            surface: 'staff',
          },
        }),
        `expected blocked event "${eventName}" to be dropped`,
      ).toBeNull();
    }
    for (const eventName of DROPPED_EVENT_TYPES) {
      expect(requiredBlockedEvents).toContain(eventName);
    }
  });

  it('drops events in before_send when Global Privacy Control or Do Not Track is enabled mid-session', () => {
    const beforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    const validEvent: CaptureResult = {
      uuid: 'evt-mid-session-opt-out',
      event: '$pageview',
      properties: {
        token: 'phc_live_key',
        distinct_id: VALID_UUID_V7,
        $pathname: '/app',
        surface: 'staff',
      },
    };

    const originalGpcDescriptor = Object.getOwnPropertyDescriptor(navigator, 'globalPrivacyControl');
    const originalDntDescriptor = Object.getOwnPropertyDescriptor(navigator, 'doNotTrack');
    try {
      Object.defineProperty(navigator, 'globalPrivacyControl', {
        configurable: true,
        value: false,
      });
      Object.defineProperty(navigator, 'doNotTrack', {
        configurable: true,
        value: '0',
      });
      expect(beforeSend(validEvent)).not.toBeNull();

      Object.defineProperty(navigator, 'globalPrivacyControl', {
        configurable: true,
        value: true,
      });
      expect(beforeSend(validEvent)).toBeNull();

      Object.defineProperty(navigator, 'globalPrivacyControl', {
        configurable: true,
        value: false,
      });
      Object.defineProperty(navigator, 'doNotTrack', {
        configurable: true,
        value: '1',
      });
      expect(beforeSend(validEvent)).toBeNull();
    } finally {
      if (originalGpcDescriptor) {
        Object.defineProperty(navigator, 'globalPrivacyControl', originalGpcDescriptor);
      } else {
        delete (navigator as unknown as Record<string, unknown>).globalPrivacyControl;
      }
      if (originalDntDescriptor) {
        Object.defineProperty(navigator, 'doNotTrack', originalDntDescriptor);
      } else {
        delete (navigator as unknown as Record<string, unknown>).doNotTrack;
      }
    }
  });

  it('keeps custom workflow events parameterless and strips any non-allowlisted custom properties in before_send', () => {
    for (const [name, helper] of Object.entries(analytics)) {
      expect(helper.length, `analytics.${name} must accept zero arguments`).toBe(0);
    }

    const customEvents = [
      'payroll_calculated',
      'payroll_approved',
      'payroll_committed',
      'checks_downloaded',
      'checks_printed',
      'report_generated',
      'employee_created',
      'timecard_uploaded',
      'timecard_ocr_applied',
      'company_switched',
    ];

    const staffBeforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'staff' });
    for (const eventName of customEvents) {
      const scrubbed = staffBeforeSend({
        uuid: `evt-${eventName}`,
        event: eventName,
        properties: {
          token: 'phc_live_key',
          distinct_id: VALID_UUID_V7,
          surface: 'staff',
          role: 'accountant',
          amount: 12500.5,
          gross_pay: 24000,
          employee_count: 14,
          company_id: 42,
          company_name: "MoSa's",
          employee_id: 99,
          employee_name: 'Ada Lovelace',
          pay_period_id: 77,
          report_type: 'w2gu',
          filename: 'timecard-ada.jpg',
          $elements: [{ tag_name: 'button', 'attr__data-ph-name': 'commit' }],
          $elements_chain: 'button:attr__data-ph-name="commit"',
        },
      });
      expect(scrubbed).toEqual({
        uuid: `evt-${eventName}`,
        event: eventName,
        properties: {
          token: 'phc_live_key',
          distinct_id: VALID_UUID_V7,
          surface: 'staff',
          role: 'accountant',
        },
      });
    }

    // Employee surface also drops role from custom events.
    const employeeBeforeSend = createBeforeSend({ projectKey: 'phc_live_key', surface: 'employee' });
    const employeeScrubbed = employeeBeforeSend({
      uuid: 'evt-emp-custom',
      event: 'report_generated',
      properties: {
        token: 'phc_live_key',
        distinct_id: VALID_UUID_V7,
        surface: 'employee',
        role: 'employee',
        amount: 999,
        statement_id: 'stmt-9',
      },
    });
    expect(employeeScrubbed?.properties).toEqual({
      token: 'phc_live_key',
      distinct_id: VALID_UUID_V7,
      surface: 'employee',
    });
  });
});

describe('analytics legacy persistence cleanup and real SDK identity isolation (PostHog 1.399.2)', () => {
  it('clears legacy ph_<token>_posthog localStorage/cookie and session keys without touching unrelated storage', () => {
    const token = 'phc_legacy_test_key';
    const legacyKey = legacyPostHogPersistenceKey(token);
    expect(legacyKey).toBe('ph_phc_legacy_test_key_posthog');

    window.localStorage.setItem(legacyKey, JSON.stringify({ distinct_id: '42', $user_id: '42' }));
    window.localStorage.setItem('unrelated_app_key', 'keep-me');
    window.sessionStorage.setItem(`ph_${token}_window_id`, 'old-win');
    window.sessionStorage.setItem(`ph_${token}_primary_window_exists`, 'true');
    document.cookie = `${legacyKey}=${encodeURIComponent(JSON.stringify({ distinct_id: '42' }))}; path=/`;
    document.cookie = 'unrelated_cookie=keep-me; path=/';

    clearLegacyPostHogPersistence(token);

    expect(window.localStorage.getItem(legacyKey)).toBeNull();
    expect(window.localStorage.getItem('unrelated_app_key')).toBe('keep-me');
    expect(window.sessionStorage.getItem(`ph_${token}_window_id`)).toBeNull();
    expect(window.sessionStorage.getItem(`ph_${token}_primary_window_exists`)).toBeNull();
    expect(document.cookie).not.toContain(`${legacyKey}=`);
    expect(document.cookie).toContain('unrelated_cookie=keep-me');
  });

  it('ignores and removes legacy persisted staff user IDs, sends zero /flags or /decide requests, and resets if distinct_id is ever tainted', () => {
    const projectKey = 'phc_real_sdk_test_key';
    const legacyKey = legacyPostHogPersistenceKey(projectKey);

    // Pre-seed legacy PostHog persistence from an older build that called identify("42").
    window.localStorage.setItem(legacyKey, JSON.stringify({ distinct_id: '42', $user_id: '42' }));
    document.cookie = `${legacyKey}=${encodeURIComponent(JSON.stringify({ distinct_id: '42', $user_id: '42' }))}; path=/`;

    window.history.replaceState(
      {},
      '',
      '/companies/ab12/employees/x9k2?__clerk_ticket=secret_clerk_ticket&__clerk_status=sign_up#/companies/42/secret',
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
    const originalSendBeaconDescriptor = Object.getOwnPropertyDescriptor(navigator, 'sendBeacon');
    Object.defineProperty(navigator, 'sendBeacon', {
      configurable: true,
      value: vi.fn((url: string) => {
        beaconUrls.push(url);
        return true;
      }),
    });

    try {
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
        VITE_PUBLIC_POSTHOG_KEY: projectKey,
        VITE_DEPLOYMENT_ENV: 'production',
        DEV: false,
      };

      const instance = new PostHog();
      const origInit = instance.init.bind(instance);
      vi.spyOn(instance, 'init').mockImplementation((token, config) => {
        const origBeforeSend = config?.before_send as (event: CaptureResult | null) => CaptureResult | null;
        return origInit(token, {
          ...config,
          request_batching: false,
          before_send: (event) => {
            const result = origBeforeSend(event);
            if (result) capturedPayloads.push(result);
            return result;
          },
        });
      });

      const started = initAnalytics({
        env,
        isStagingEnv: false,
        hasSupportToken: false,
        navigatorObj: {},
        windowObj: {},
        surface: 'staff',
        client: instance,
      });
      expect(started).toBe(true);

      // Legacy persistence must be removed and the new v2 anonymous persistence key used instead.
      expect(window.localStorage.getItem(legacyKey)).toBeNull();
      expect(document.cookie).not.toContain(`${legacyKey}=`);
      expect(window.localStorage.getItem(`ph_${ANALYTICS_PERSISTENCE_NAME}`)).not.toBeNull();
      expect(instance.get_distinct_id()).not.toBe('42');
      expect(isAnonymousDistinctId(instance.get_distinct_id())).toBe(true);

      // Trigger pageview, blocked events, and explicit reloadFeatureFlags (must stay disabled).
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

      // Real SDK produced the $pageview with matched route template and valid UUIDv7 distinct_id.
      expect(capturedPayloads.map((e) => e.event)).toEqual(['$pageview']);
      const payload = capturedPayloads[0];
      expect(payload.properties.$pathname).toBe('/companies/:companyId/employees/:id');
      expect(payload.properties.$current_url).toBe(
        `${window.location.origin}/companies/:companyId/employees/:id`,
      );
      expect(isAnonymousDistinctId(payload.properties.distinct_id)).toBe(true);
      expect(payload.properties.distinct_id).not.toBe('42');
      expect(payload.properties.surface).toBe('staff');
      expect(payload.properties.token).toBe(projectKey);
      expect(payload.properties).not.toHaveProperty('$session_entry_url');
      expect(payload.properties).not.toHaveProperty('$session_entry_referrer');
      expect(payload.properties).not.toHaveProperty('$initial_current_url');
      expect(payload.properties).not.toHaveProperty('$initial_referrer');
      expect(payload.properties).not.toHaveProperty('$referrer');
      expect(payload).not.toHaveProperty('$set');
      expect(payload).not.toHaveProperty('$set_once');
      expect(JSON.stringify(payload)).not.toContain('__clerk_ticket');
      expect(JSON.stringify(payload)).not.toContain('__clerk_status');
      expect(JSON.stringify(payload)).not.toContain('ab12');
      expect(JSON.stringify(payload)).not.toContain('x9k2');

      // Defense-in-depth: if distinct_id is ever tainted with a non-UUIDv7 value,
      // before_send drops the event and triggers reset(), regenerating a fresh UUIDv7.
      const resetSpy = vi.spyOn(instance, 'reset');
      instance.register({ distinct_id: '42' });
      instance.capture('payroll_calculated');
      expect(resetSpy).toHaveBeenCalledTimes(1);
      expect(capturedPayloads).toHaveLength(1); // tainted event was dropped
      expect(isAnonymousDistinctId(instance.get_distinct_id())).toBe(true);
      expect(instance.get_distinct_id()).not.toBe('42');

      // Subsequent event after reset succeeds with the new anonymous UUIDv7.
      instance.capture('payroll_approved');
      expect(capturedPayloads).toHaveLength(2);
      expect(capturedPayloads[1].event).toBe('payroll_approved');
      expect(isAnonymousDistinctId(capturedPayloads[1].properties.distinct_id)).toBe(true);
    } finally {
      if (originalSendBeaconDescriptor) {
        Object.defineProperty(navigator, 'sendBeacon', originalSendBeaconDescriptor);
      } else {
        delete (navigator as unknown as Record<string, unknown>).sendBeacon;
      }
    }
  });

  it('keeps development opt-out in effect after resetAnalytics so subsequent captures remain rejected', () => {
    const capturedPayloads: CaptureResult[] = [];
    const instance = new PostHog();
    const origInit = instance.init.bind(instance);
    vi.spyOn(instance, 'init').mockImplementation((token, config) => {
      const origBeforeSend = config?.before_send as (event: CaptureResult | null) => CaptureResult | null;
      return origInit(token, {
        ...config,
        request_batching: false,
        before_send: (event) => {
          const result = origBeforeSend(event);
          if (result) capturedPayloads.push(result);
          return result;
        },
      });
    });

    const started = initAnalytics({
      env: {
        VITE_PUBLIC_POSTHOG_ENABLED: 'true',
        VITE_PUBLIC_POSTHOG_KEY: 'phc_dev_opt_out_test_key',
        VITE_DEPLOYMENT_ENV: 'production',
        DEV: true,
      },
      isStagingEnv: false,
      hasSupportToken: false,
      navigatorObj: {},
      windowObj: {},
      surface: 'staff',
      client: instance,
    });
    expect(started).toBe(true);
    expect(instance.has_opted_out_capturing()).toBe(true);

    const beforeResetId = instance.get_distinct_id();
    resetAnalytics(instance, { surface: 'staff', keepRole: true, isDev: true });

    expect(instance.get_distinct_id()).not.toBe(beforeResetId);
    expect(instance.has_opted_out_capturing()).toBe(true);

    capturePageView(instance, '/app', 'staff');
    instance.capture('payroll_calculated');
    expect(capturedPayloads).toEqual([]);
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

  it('captures matched route templates (and /unknown for unmatched paths) in both $pathname and $current_url', () => {
    const capture = vi.fn();
    capturePageView({ capture }, '/companies/ab12/employees/x9k2?__clerk_ticket=secret#/hash', 'staff');
    expect(capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/companies/:companyId/employees/:id`,
      $pathname: '/companies/:companyId/employees/:id',
      surface: 'staff',
    });

    capture.mockClear();
    capturePageView({ capture }, '/arbitrary-secret/a1b2', 'staff');
    expect(capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/unknown`,
      $pathname: '/unknown',
      surface: 'staff',
    });

    capture.mockClear();
    capturePageView({ capture }, '/pay/x9k2?year=2026#dl', 'employee');
    expect(capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/pay/:statementId`,
      $pathname: '/pay/:statementId',
      surface: 'employee',
    });

    capture.mockClear();
    capturePageView({ capture }, '/not-an-employee-route/k3m', 'employee');
    expect(capture).toHaveBeenCalledWith('$pageview', {
      $current_url: `${window.location.origin}/unknown`,
      $pathname: '/unknown',
      surface: 'employee',
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

  it('initializes with strict privacy options, v2 anonymous persistence, and no dead ip: false option', () => {
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
      persistence: 'localStorage+cookie',
      persistence_name: ANALYTICS_PERSISTENCE_NAME,
      cross_subdomain_cookie: false,
      respect_dnt: true,
    });
    expect(config).not.toHaveProperty('ip');
    expect(config.autocapture).toEqual({
      css_selector_ignorelist: expect.arrayContaining(['input', 'textarea', 'select', '[data-ph-no-capture]']),
    });
    expect(typeof config.before_send).toBe('function');
    expect(typeof config.get_current_url).toBe('function');
    expect(
      config.get_current_url?.('https://payroll.shimizu-technology.com/companies/ab12/employees/x9?__clerk_ticket=abc#/frag'),
    ).toBe('https://payroll.shimizu-technology.com/companies/:companyId/employees/:id');
    expect(
      config.get_current_url?.('https://payroll.shimizu-technology.com/companies/ab12?__clerk_ticket=abc#/frag'),
    ).toBe('https://payroll.shimizu-technology.com/unknown');
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

  it('resets analytics in PostHogSessionSync when staff user ID changes directly without an intervening null', async () => {
    vi.resetModules();
    vi.unstubAllEnvs();
    vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production');
    vi.stubEnv('VITE_PUBLIC_POSTHOG_ENABLED', 'true');
    vi.stubEnv('VITE_PUBLIC_POSTHOG_KEY', 'phc_session_sync_test_key');

    let currentUser: { id: number; role: string } | null = { id: 101, role: 'accountant' };
    const callOrder: string[] = [];
    const posthogMock = {
      reset: vi.fn(() => callOrder.push('reset')),
      register: vi.fn((props: Record<string, unknown>) => callOrder.push(`register:${String(props.role ?? 'none')}`)),
      unregister: vi.fn(),
      opt_out_capturing: vi.fn(),
      has_opted_out_capturing: vi.fn(() => false),
    };

    vi.doMock('@/contexts/AuthContext', () => ({
      AuthProvider: ({ children }: { children: unknown }) => children,
      useAuth: () => ({ user: currentUser }),
    }));
    vi.doMock('posthog-js/react', () => ({
      PostHogProvider: ({ children }: { children: unknown }) => children,
      usePostHog: () => posthogMock,
    }));

    try {
      const { PostHogSessionSync } = await import('../App');
      const { rerender } = render(<PostHogSessionSync />);

      expect(posthogMock.reset).not.toHaveBeenCalled();
      expect(posthogMock.register).toHaveBeenCalledWith({ surface: 'staff', role: 'accountant' });

      // Same user ID with updated role: re-registers role without resetting anonymous ID.
      currentUser = { id: 101, role: 'admin' };
      rerender(<PostHogSessionSync />);
      expect(posthogMock.reset).not.toHaveBeenCalled();
      expect(posthogMock.register).toHaveBeenCalledWith({ surface: 'staff', role: 'admin' });

      // Direct switch to a different staff user ID without an intervening null user: must reset first.
      callOrder.length = 0;
      currentUser = { id: 202, role: 'manager' };
      rerender(<PostHogSessionSync />);
      expect(posthogMock.reset).toHaveBeenCalledTimes(1);
      expect(callOrder[0]).toBe('reset');
      expect(posthogMock.register).toHaveBeenLastCalledWith({ surface: 'staff', role: 'manager' });

      // Signing out to null resets once and clears role.
      currentUser = null;
      rerender(<PostHogSessionSync />);
      expect(posthogMock.reset).toHaveBeenCalledTimes(2);
      expect(posthogMock.unregister).toHaveBeenCalledWith('role');

      // Staying signed out does not reset again.
      rerender(<PostHogSessionSync />);
      expect(posthogMock.reset).toHaveBeenCalledTimes(2);
    } finally {
      cleanup();
      vi.doUnmock('@/contexts/AuthContext');
      vi.doUnmock('posthog-js/react');
      vi.resetModules();
    }
  });
});
