/** @vitest-environment node */
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const rules = readFileSync(path.join(webDir, 'public', '_redirects'), 'utf8')
  .split('\n')
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith('#'))
  .map((line) => line.split(/\s+/));

describe('Payroll _redirects', () => {
  it('sends the old Netlify address to the real domain before any other rule', () => {
    expect(rules[0]).toEqual([
      'https://cornerstone-payroll.netlify.app/*',
      'https://payroll.shimizu-technology.com/:splat',
      '301!',
    ]);
  });

  it('never redirects the real domain', () => {
    expect(rules.some(([from]) => from.includes('payroll.shimizu-technology.com'))).toBe(false);
  });

  it('keeps the SPA fallback as the last rule', () => {
    expect(rules[rules.length - 1]).toEqual(['/*', '/index.html', '200']);
  });
});
