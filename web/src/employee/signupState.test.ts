// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { arrivedAt, currentInviteToken, forgetInviteToken, rateLimitedText, takeInviteToken } from './signupState';

const TOKEN = 'a'.repeat(40);

describe('invite token', () => {
  afterEach(() => {
    forgetInviteToken();
    window.history.replaceState(null, '', '/');
  });

  it('takes #token out of the address bar and keeps it for this tab only', () => {
    window.history.replaceState(null, '', `/claim?tenantHost=x#token=${TOKEN}`);
    takeInviteToken(window.location);
    expect(window.location.hash).toBe('');
    expect(window.location.search).toBe('?tenantHost=x');
    expect(currentInviteToken()).toBe(TOKEN);
    expect(sessionStorage.getItem('employee-invite-token')).toBe(TOKEN);
  });

  it('survives a full-page sign-in redirect, then is gone once forgotten', () => {
    sessionStorage.setItem('employee-invite-token', TOKEN);
    expect(currentInviteToken()).toBe(TOKEN);
    forgetInviteToken();
    expect(currentInviteToken()).toBeNull();
    expect(sessionStorage.getItem('employee-invite-token')).toBeNull();
  });

  it('ignores a malformed token but still strips it, and never reads one from the query string', () => {
    window.history.replaceState(null, '', '/activate#token=<script>');
    takeInviteToken(window.location);
    expect(window.location.hash).toBe('');
    expect(currentInviteToken()).toBeNull();
    window.history.replaceState(null, '', `/activate?token=${TOKEN}`);
    takeInviteToken(window.location);
    expect(currentInviteToken()).toBeNull();
  });
});

describe('rateLimitedText', () => {
  it('rounds Retry-After up to whole minutes, with a one-minute fallback', () => {
    expect(rateLimitedText(null)).toBe('Too many tries. Wait a minute, then try again.');
    expect(rateLimitedText(undefined)).toBe('Too many tries. Wait a minute, then try again.');
    expect(rateLimitedText(60)).toBe('Too many tries. Wait a minute, then try again.');
    expect(rateLimitedText(61)).toBe('Too many tries. Wait about 2 minutes, then try again.');
    expect(rateLimitedText(90)).toBe('Too many tries. Wait about 2 minutes, then try again.');
    // The per-code throttle that a sign-up lockout uses up lasts 15 minutes.
    expect(rateLimitedText(900)).toBe('Too many tries. Wait about 15 minutes, then try again.');
  });
});

describe('arrivedAt', () => {
  afterEach(() => sessionStorage.clear());

  it('clears a kept return path once the app reaches it, ignoring a trailing slash, query or hash', () => {
    sessionStorage.setItem('employee-sign-in-return', '/pay/');
    arrivedAt('/pay');
    expect(sessionStorage.getItem('employee-sign-in-return')).toBeNull();

    sessionStorage.setItem('employee-sign-in-return', '/pay/12?year=2026#top');
    arrivedAt('/pay/12');
    expect(sessionStorage.getItem('employee-sign-in-return')).toBeNull();
  });

  it('keeps it on any other page', () => {
    sessionStorage.setItem('employee-sign-in-return', '/claim');
    arrivedAt('/');
    expect(sessionStorage.getItem('employee-sign-in-return')).toBe('/claim');
  });
});
