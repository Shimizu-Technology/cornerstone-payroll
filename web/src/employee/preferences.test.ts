/** @vitest-environment node */
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  HIDE_AMOUNTS_EXPLAINED_KEY,
  HIDE_AMOUNTS_KEY,
  readHideAmounts,
  readHideAmountsExplained,
  writeHideAmounts,
  writeHideAmountsExplained,
} from './preferences';

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length(): number { return values.size; },
    clear: (): void => values.clear(),
    getItem: (key: string): string | null => values.get(key) ?? null,
    key: (index: number): string | null => [...values.keys()][index] ?? null,
    removeItem: (key: string): void => { values.delete(key); },
    setItem: (key: string, value: string): void => { values.set(key, value); },
  };
}

afterEach(() => {
  Reflect.deleteProperty(globalThis, 'localStorage');
});

describe('Hide amounts preference', () => {
  it('defaults to hiding amounts and remembers an explicit device choice', () => {
    const storage = memoryStorage();
    expect(readHideAmounts(() => storage)).toBe(true);

    writeHideAmounts(false, () => storage);
    expect(storage.getItem(HIDE_AMOUNTS_KEY)).toBe('false');
    expect(readHideAmounts(() => storage)).toBe(false);

    writeHideAmounts(true, () => storage);
    expect(storage.getItem(HIDE_AMOUNTS_KEY)).toBe('true');
    expect(readHideAmounts(() => storage)).toBe(true);

    // Unexpected stored values fail closed to hidden.
    storage.setItem(HIDE_AMOUNTS_KEY, 'unexpected');
    expect(readHideAmounts(() => storage)).toBe(true);
  });

  it('falls back to hiding amounts when storage methods throw or storage is missing', () => {
    const blocked = {
      getItem: vi.fn((): never => { throw new DOMException('denied', 'SecurityError'); }),
      setItem: vi.fn((): never => { throw new DOMException('full', 'QuotaExceededError'); }),
      removeItem: vi.fn(),
    };
    expect(readHideAmounts(() => blocked)).toBe(true);
    expect(() => writeHideAmounts(false, () => blocked)).not.toThrow();
    expect(() => writeHideAmounts(true, () => blocked)).not.toThrow();
    expect(readHideAmounts(() => undefined)).toBe(true);
  });

  it('survives a browser where even reading window.localStorage throws, failing closed to masked', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      get(): never { throw new DOMException('The operation is insecure.', 'SecurityError'); },
    });
    expect(readHideAmounts()).toBe(true);
    expect(readHideAmountsExplained()).toBe(false);
    expect(() => writeHideAmounts(false)).not.toThrow();
    expect(() => writeHideAmounts(true)).not.toThrow();
    expect(() => writeHideAmountsExplained()).not.toThrow();
  });

  it('remembers that the one-time explainer was shown on this device', () => {
    const storage = memoryStorage();
    expect(readHideAmountsExplained(() => storage)).toBe(false);
    writeHideAmountsExplained(() => storage);
    expect(storage.getItem(HIDE_AMOUNTS_EXPLAINED_KEY)).toBe('true');
    expect(readHideAmountsExplained(() => storage)).toBe(true);
  });

  it('is the only place the employee app touches localStorage', () => {
    const root = path.resolve(__dirname);
    const files = readdirSync(root).filter((name) => /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name));
    const users = files.filter((name) => readFileSync(path.join(root, name), 'utf8').includes('localStorage'));
    expect(users).toEqual(['preferences.ts']);
    expect(readFileSync(path.resolve(root, '../EmployeeApp.tsx'), 'utf8')).not.toContain('localStorage');
  });
});
