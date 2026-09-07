import { describe, expect, it } from 'vitest';
import { parsePositiveRouteId } from './route-params';

describe('parsePositiveRouteId', (): void => {
  it('accepts canonical positive decimal identifiers', (): void => {
    expect(parsePositiveRouteId('1')).toBe(1);
    expect(parsePositiveRouteId('123')).toBe(123);
  });

  it.each([undefined, '', '0', '-1', '01', '1.5', '1e3', '0x10', '123abc', '9007199254740992'])(
    'rejects a non-canonical or unsafe identifier: %s',
    (value): void => {
      expect(parsePositiveRouteId(value)).toBeUndefined();
    },
  );
});
