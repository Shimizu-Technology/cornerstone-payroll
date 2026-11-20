import { describe, expect, it } from 'vitest';
import { contrastRatio, initialsFor, normalizeHex, textOnAccent, themeDefaultAccent } from './invoiceStyle';

describe('invoice style helpers', () => {
  it('normalizes hex colors and rejects anything else', () => {
    expect(normalizeHex(' #1f4e79 ')).toBe('#1F4E79');
    expect(normalizeHex('0F766E')).toBe('#0F766E');
    ['#12345', 'navy', '#1234567', ''].forEach((value) => expect(normalizeHex(value)).toBeNull());
  });

  it('picks white or black text so any accent reads at 4.5:1', () => {
    expect(textOnAccent('#1F4E79')).toBe('#FFFFFF');
    expect(textOnAccent('#FDE047')).toBe('#000000');
    for (let index = 0; index < 300; index += 1) {
      const color = `#${((index * 2654435761) % 0x1000000).toString(16).padStart(6, '0').toUpperCase()}`;
      expect(contrastRatio(color, textOnAccent(color))).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('matches the PDF monogram and theme defaults', () => {
    expect(initialsFor('Marianas Bay CPA')).toBe('MB');
    expect(initialsFor('Cornerstone')).toBe('CO');
    expect(themeDefaultAccent('banner')).toBe('#1E40AF');
  });
});
