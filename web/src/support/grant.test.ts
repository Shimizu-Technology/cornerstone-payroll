// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { supportExitDestination } from './grant';

describe('supportExitDestination', () => {
  it("sends End from an employee-app view to the staff site's dashboard", () => {
    expect(supportExitDestination({ staff_url: 'https://payroll.example.com' }, '/')).toBe('https://payroll.example.com/app');
    expect(supportExitDestination({ staff_url: 'https://payroll.cornerstone.localhost:8443' }, '/')).toBe('https://payroll.cornerstone.localhost:8443/app');
  });

  it('keeps the fallback when the grant has no usable staff URL', () => {
    expect(supportExitDestination(null, '/app')).toBe('/app');
    expect(supportExitDestination({ staff_url: null }, '/')).toBe('/');
    expect(supportExitDestination({ staff_url: 'not a url' }, '/')).toBe('/');
    expect(supportExitDestination({ staff_url: 'javascript:alert(1)' }, '/')).toBe('/');
  });
});
