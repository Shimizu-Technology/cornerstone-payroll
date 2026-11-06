import { describe, expect, it } from 'vitest';
import cases from './__fixtures__/draft-gross.json';
import { estimateDraftGross, type DraftGrossInput } from './draft-gross';
describe('draft gross contract shared with the server calculators', () => {
  it.each(cases)('$name matches server gross $expected', scenario => {
    expect(estimateDraftGross(scenario as unknown as DraftGrossInput)).toBe(scenario.expected);
  });
});
