import { describe, expect, it } from 'vitest';
import {
  FALLBACK_BRAND_COLOR, INK, MIN_TEXT_CONTRAST, NEUTRAL_ACTION_COLOR,
  accentColorCheck, accentPair, actionColorFor, brandColorCheck, brandRoles, contrastRatio, contrastWithWhite,
} from './tenant-brand-colors';

describe('tenant brand colors', () => {
  it("darkens MoSa's logo blue for buttons and keeps the original for decoration", () => {
    expect(contrastWithWhite('#1898cf')).toBeLessThan(MIN_TEXT_CONTRAST);

    const roles = brandRoles('#1898CF', '#FADF06');

    expect(roles.actionAdjusted).toBe(true);
    expect(contrastWithWhite(roles.action)).toBeGreaterThanOrEqual(MIN_TEXT_CONTRAST);
    // Close to the audit's hand-picked #1A6F99 (5.56 to 1), not darker than needed.
    expect(contrastWithWhite(roles.action)).toBeLessThan(6);
    expect(roles.decoration).toBe('#1898cf');
    // The logo blue stands out from white, so it can mark the active tab.
    expect(roles.indicator).toBe('#1898cf');
    expect(roles.accent).toBe('#fadf06');
    expect(roles.accentInk).toBe(INK);
  });

  it('never puts white text on a light color', () => {
    const yellow = actionColorFor('#FADF06');
    expect(yellow).toEqual({ color: NEUTRAL_ACTION_COLOR, adjusted: true });

    const roles = brandRoles('#fadf06');
    expect(roles.action).toBe(NEUTRAL_ACTION_COLOR);
    expect(roles.accent).toBe('#fadf06');
    expect(roles.accentInk).toBe(INK);
    expect(contrastRatio(roles.accent, roles.accentInk)).toBeGreaterThanOrEqual(MIN_TEXT_CONTRAST);
    expect(roles.indicator).toBe(NEUTRAL_ACTION_COLOR);
  });

  it('uses a dark color as it is and falls back to payroll blue without one', () => {
    expect(actionColorFor('#0f263d')).toEqual({ color: '#0f263d', adjusted: false });
    expect(brandRoles(null).decoration).toBe(FALLBACK_BRAND_COLOR);
    expect(brandRoles('blue').decoration).toBe(FALLBACK_BRAND_COLOR);
  });

  it('pairs every accent with text that passes', () => {
    for (const color of ['#fadf06', '#0f263d', '#ee5e25', '#1898cf', '#808080', '#2e8b57']) {
      const { accent, ink } = accentPair(color);
      expect(contrastRatio(accent, ink)).toBeGreaterThanOrEqual(MIN_TEXT_CONTRAST);
    }
  });

  it('explains the result in plain words', () => {
    expect(brandColorCheck('#1898CF')).toEqual({
      tone: 'adjusted', ratio: '3.2 to 1', message: 'Buttons will use this darker shade so text is readable.',
    });
    expect(brandColorCheck('#FADF06').tone).toBe('light');
    expect(brandColorCheck('#FADF06').message).toContain('used for highlights with dark text');
    expect(brandColorCheck('#FADF06', true).message).toContain('your accent color is used for highlights');
    expect(brandColorCheck('#0F263D').tone).toBe('ok');
    expect(accentColorCheck('#FADF06')).toBe('Highlights use this color with dark text.');
    expect(accentColorCheck('#0F263D')).toBe('Highlights use this color with white text.');
    // Sea green fails with both dark and white text, so it's lightened.
    expect(accentColorCheck('#2e8b57')).toContain('lighter tint');
  });
});
