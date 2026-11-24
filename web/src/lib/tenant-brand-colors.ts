// How a client's brand colors are used in the employee app. The settings page
// and the employee app share this rule, so the preview matches what employees
// see. It mirrors web/src/employee/brand.ts from PR #556; once both are merged,
// brand.ts should import these functions instead of keeping its own copy.
//
// Colors become roles, never raw paint:
// - action: buttons, links and the active tab. Always passes 4.5:1 under white text.
// - decoration: the client's own color, for non-text accents only.
// - indicator: tab underlines. The client's color when it stands out from white (3:1),
//   otherwise the action color.
// - accent: chips and highlights, always paired with accentInk (usually dark text).
// A light client color, such as a yellow, never carries white text: it becomes the
// accent with dark text, and buttons use a neutral dark shade instead.

// Payroll blue (primary-700 in index.css).
export const FALLBACK_BRAND_COLOR = '#194baa';
// Slate-800, for buttons when the client's color is too light to carry white text.
export const NEUTRAL_ACTION_COLOR = '#1e293b';
export const INK = '#0f172a';
const WHITE = '#ffffff';
// Warning-100 from index.css: the chip color when a client has no usable accent.
const DEFAULT_ACCENT = '#fef3c7';

export const MIN_TEXT_CONTRAST = 4.5;
export const MIN_INDICATOR_CONTRAST = 3;
// Colors lighter than this are "light": darkening them enough for white text
// turns them muddy, so they stay as accents with dark text.
const LIGHT_LUMINANCE = 0.4;

const HEX_COLOR = /^#[0-9a-f]{6}$/i;

type Rgb = [number, number, number];

export function isHexColor(value: unknown): value is string {
  return typeof value === 'string' && HEX_COLOR.test(value);
}

function hexToRgb(hex: string): Rgb {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function rgbToHex(rgb: Rgb): string {
  return `#${rgb.map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, '0')).join('')}`;
}

function relativeLuminance(hex: string): number {
  const channel = (v: number) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  const [r, g, b] = hexToRgb(hex);
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export function contrastRatio(a: string, b: string): number {
  const [light, dark] = [relativeLuminance(a), relativeLuminance(b)].sort((x, y) => y - x);
  return (light + 0.05) / (dark + 0.05);
}

export function contrastWithWhite(hex: string): number {
  return contrastRatio(hex, WHITE);
}

/** Darken a color until white text on it passes 4.5:1, for reading in sunlight. */
export function readableBrandColor(hex: string): { color: string; adjusted: boolean } {
  let rgb = hexToRgb(hex);
  let steps = 0;
  while (contrastWithWhite(rgbToHex(rgb)) < MIN_TEXT_CONTRAST && steps < 60) {
    rgb = rgb.map((v) => v * 0.93) as Rgb;
    steps += 1;
  }
  return { color: rgbToHex(rgb), adjusted: steps > 0 };
}

export function isLightColor(hex: string): boolean {
  return relativeLuminance(hex) > LIGHT_LUMINANCE;
}

/** The button color for a client color: as entered, a darker shade, or neutral for light colors. */
export function actionColorFor(hex: string): { color: string; adjusted: boolean } {
  if (contrastWithWhite(hex) >= MIN_TEXT_CONTRAST) return { color: hex, adjusted: false };
  if (isLightColor(hex)) return { color: NEUTRAL_ACTION_COLOR, adjusted: true };
  return readableBrandColor(hex);
}

export function tintOf(hex: string, amount = 0.9): string {
  return rgbToHex(hexToRgb(hex).map((v) => v + (255 - v) * amount) as Rgb);
}

/** A chip color and the text that goes on it. Dark text unless only white passes. */
export function accentPair(hex: string): { accent: string; ink: string } {
  if (contrastRatio(hex, INK) >= MIN_TEXT_CONTRAST) return { accent: hex, ink: INK };
  if (contrastWithWhite(hex) >= MIN_TEXT_CONTRAST) return { accent: hex, ink: WHITE };
  // A mid-tone that suits neither: lighten it until dark text passes.
  let color = hex;
  for (let amount = 0.1; contrastRatio(color, INK) < MIN_TEXT_CONTRAST && amount <= 1; amount += 0.1) {
    color = tintOf(hex, amount);
  }
  return { accent: color, ink: INK };
}

export interface BrandRoles {
  action: string;
  actionAdjusted: boolean;
  actionTint: string;
  decoration: string;
  indicator: string;
  accent: string;
  accentInk: string;
}

/** The colors the employee app uses for a client's brand and accent colors. */
export function brandRoles(primaryColor: string | null | undefined, accentColor?: string | null): BrandRoles {
  const primary = isHexColor(primaryColor) ? primaryColor.toLowerCase() : FALLBACK_BRAND_COLOR;
  const { color: action, adjusted } = actionColorFor(primary);
  const accentSource = isHexColor(accentColor) ? accentColor.toLowerCase() : (isLightColor(primary) ? primary : DEFAULT_ACCENT);
  const { accent, ink } = accentPair(accentSource);
  return {
    action,
    actionAdjusted: adjusted,
    actionTint: tintOf(action),
    decoration: primary,
    indicator: contrastWithWhite(primary) >= MIN_INDICATOR_CONTRAST ? primary : action,
    accent,
    accentInk: ink,
  };
}

/** CSS custom properties for the brand roles. */
export function brandRoleStyle(roles: BrandRoles): Record<string, string> {
  return {
    '--action': roles.action,
    '--action-tint': roles.actionTint,
    '--brand': roles.decoration,
    '--indicator': roles.indicator,
    '--accent': roles.accent,
    '--accent-ink': roles.accentInk,
  };
}

export type ColorCheckTone = 'ok' | 'adjusted' | 'light';

export interface ColorCheck {
  tone: ColorCheckTone;
  /** One plain sentence for the person choosing the color. */
  message: string;
  /** "5.6 to 1", for the details line. */
  ratio: string;
}

function ratioText(ratio: number): string {
  return `${(Math.floor(ratio * 10) / 10).toFixed(1)} to 1`;
}

/** What happens to a brand color, in words an admin can act on. */
export function brandColorCheck(primaryColor: string): ColorCheck {
  const color = primaryColor.toLowerCase();
  const ratio = contrastWithWhite(color);
  if (ratio >= MIN_TEXT_CONTRAST) {
    return { tone: 'ok', ratio: ratioText(ratio), message: 'Buttons use this color as it is. White text on it is easy to read.' };
  }
  if (isLightColor(color)) {
    return {
      tone: 'light',
      ratio: ratioText(ratio),
      message: 'This color is too light for white text. Buttons will be dark gray, and this color is used for highlights with dark text.',
    };
  }
  return { tone: 'adjusted', ratio: ratioText(ratio), message: 'Buttons will use this darker shade so text is readable.' };
}

/** What happens to the optional accent color. */
export function accentColorCheck(accentColor: string): string {
  const { accent, ink } = accentPair(accentColor.toLowerCase());
  if (accent !== accentColor.toLowerCase()) return 'Highlights will use a lighter tint of this color so dark text stays readable.';
  return ink === INK ? 'Highlights use this color with dark text.' : 'Highlights use this color with white text.';
}
