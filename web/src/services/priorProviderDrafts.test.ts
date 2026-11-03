// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { authApi } from './api';
afterEach(() => sessionStorage.clear());
it('clears all users and clients history drafts on logout while preserving unrelated session data', () => {
  sessionStorage.setItem('prior-provider-history:1:10', 'private payroll');
  sessionStorage.setItem('prior-provider-history:2:11', 'another payroll');
  sessionStorage.setItem('unrelated', 'keep');
  authApi.logout();
  expect(sessionStorage.getItem('prior-provider-history:1:10')).toBeNull();
  expect(sessionStorage.getItem('prior-provider-history:2:11')).toBeNull();
  expect(sessionStorage.getItem('unrelated')).toBe('keep');
});
