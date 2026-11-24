/** @vitest-environment node */
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { HIDE_AMOUNTS_KEY, readHideAmounts, writeHideAmounts } from './preferences';

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); },
    setItem: (key, value) => { values.set(key, value); },
  };
}

describe('Hide amounts preference', () => {
  it('defaults to showing amounts and remembers the choice', () => {
    const storage = memoryStorage();
    expect(readHideAmounts(storage)).toBe(false);
    writeHideAmounts(true, storage);
    expect(storage.getItem(HIDE_AMOUNTS_KEY)).toBe('true');
    expect(readHideAmounts(storage)).toBe(true);
    writeHideAmounts(false, storage);
    expect(storage.length).toBe(0);
  });

  it('shows amounts when storage is blocked, and never throws', () => {
    const blocked = { getItem: vi.fn(() => { throw new DOMException('denied', 'SecurityError'); }), setItem: vi.fn(() => { throw new DOMException('full', 'QuotaExceededError'); }), removeItem: vi.fn() };
    expect(readHideAmounts(blocked)).toBe(false);
    expect(() => writeHideAmounts(true, blocked)).not.toThrow();
    expect(readHideAmounts(undefined)).toBe(false);
  });

  it('is the only place the employee app touches localStorage', () => {
    const root = path.resolve(__dirname);
    const files = readdirSync(root).filter((name) => /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name));
    const users = files.filter((name) => readFileSync(path.join(root, name), 'utf8').includes('localStorage'));
    expect(users).toEqual(['preferences.ts']);
    expect(readFileSync(path.resolve(root, '../EmployeeApp.tsx'), 'utf8')).not.toContain('localStorage');
  });
});
