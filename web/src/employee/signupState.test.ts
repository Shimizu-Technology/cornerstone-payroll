// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { currentInviteToken, forgetInviteToken, takeInviteToken } from './signupState';

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
