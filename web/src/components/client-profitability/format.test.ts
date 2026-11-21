import { describe, expect, it } from 'vitest';
import { defaultPeriod } from './format';

describe('defaultPeriod', () => {
  const today = new Date(2026, 10, 22); // November 22, 2026

  it('opens on last month for month and custom', () => {
    expect(defaultPeriod('month', today)).toEqual({ from: '2026-10', through: '2026-10' });
    expect(defaultPeriod('custom', today)).toEqual({ from: '2026-10', through: '2026-10' });
  });

  it('opens on the quarter that holds last month', () => {
    expect(defaultPeriod('quarter', today)).toEqual({ from: '2026-10', through: '2026-12' });
    expect(defaultPeriod('quarter', new Date(2026, 0, 10))).toEqual({ from: '2025-10', through: '2025-12' });
  });
});
