// Tenant branding for the employee app. GET /api/v1/public/tenant_branding
// returns { name, logo_url, primary_color, accent_color } for an enabled client
// subdomain, or 404. Anything else falls back to a neutral Cornerstone brand.
//
// A client's colors become roles, never raw paint:
// - action: buttons, links and the active tab. Always passes 4.5:1 under white text.
// - decoration: the client's own color, for non-text accents only.
// - indicator: tab underlines and selection bars. The client's color when it stands
//   out from white (3:1), otherwise the action color.
// - accent: chips and highlights, always paired with accentInk (usually dark text).
// A light client color, such as a yellow, never carries white text: it becomes the
// accent with dark text, and buttons use a neutral dark shade instead.

export interface TenantBranding {
  name: string;
  logo_url: string | null;
  primary_color: string | null;
  accent_color: string | null;
}

export interface EmployeeBrand {
  name: string;
  logoUrl: string | null;
  monogram: string;
  /** True when no client branding was found; copy then avoids naming an employer. */
  isFallback: boolean;
  action: string;
  /** True when the action color isn't the client's color as entered. */
  actionAdjusted: boolean;
  /** A light tint of the action color, for icon backgrounds. */
  actionTint: string;
  decoration: string;
  indicator: string;
  accent: string;
  accentInk: string;
}

export const FALLBACK_BRAND_NAME = 'Cornerstone Payroll';
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

function monogramOf(name: string): string {
  const letter = name.match(/[\p{L}\p{N}]/u)?.[0];
  return letter ? letter.toUpperCase() : 'C';
}

function httpsUrl(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  try {
    return new URL(value).protocol === 'https:' ? value : null;
  } catch {
    return null;
  }
}

function hexOrNull(value: string | null | undefined): string | null {
  return value && HEX_COLOR.test(value) ? value.toLowerCase() : null;
}

export function brandFrom(branding: TenantBranding | null): EmployeeBrand {
  const name = branding?.name?.trim() || FALLBACK_BRAND_NAME;
  const primary = hexOrNull(branding?.primary_color) ?? FALLBACK_BRAND_COLOR;
  const { color: action, adjusted } = actionColorFor(primary);
  const accentSource = hexOrNull(branding?.accent_color) ?? (isLightColor(primary) ? primary : DEFAULT_ACCENT);
  const { accent, ink } = accentPair(accentSource);
  return {
    name,
    logoUrl: branding ? httpsUrl(branding.logo_url) : null,
    monogram: monogramOf(name),
    isFallback: !branding,
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
export function brandStyle(brand: EmployeeBrand): Record<string, string> {
  return {
    '--action': brand.action,
    '--action-tint': brand.actionTint,
    '--brand': brand.decoration,
    '--indicator': brand.indicator,
    '--accent': brand.accent,
    '--accent-ink': brand.accentInk,
  };
}

function isTenantBranding(value: unknown): value is TenantBranding {
  return value !== null && typeof value === 'object' && typeof (value as TenantBranding).name === 'string'
    && (value as TenantBranding).name.trim() !== '';
}

/** Returns null on 404, a network failure or a malformed response, so the caller falls back. */
export async function fetchTenantBranding(
  host: string,
  { baseUrl, signal, fetchImpl = fetch }: { baseUrl: string; signal?: AbortSignal; fetchImpl?: typeof fetch },
): Promise<TenantBranding | null> {
  try {
    const url = new URL(`${baseUrl}/public/tenant_branding`, globalThis.location?.origin ?? 'http://localhost');
    url.searchParams.set('host', host);
    const response = await fetchImpl(url, { credentials: 'omit', cache: 'no-store', signal, headers: { Accept: 'application/json' } });
    if (!response.ok) return null;
    const data: unknown = await response.json();
    return isTenantBranding(data) ? data : null;
  } catch {
    return null;
  }
}

/**
 * "MoSa's" stays "MoSa's", "Pelican Row Bakery" becomes "Pelican Row Bakery's",
 * and "Two Brothers" becomes "Two Brothers'". Company names often already end in 's.
 */
export function possessive(name: string): string {
  const trimmed = name.trim();
  if (/['’]s$/i.test(trimmed)) return trimmed;
  if (/s$/i.test(trimmed)) return `${trimmed}'`;
  return `${trimmed}'s`;
}

/** "Ask your manager at MoSa's." Without client branding we don't know the employer's name. */
export function askManager(brand: EmployeeBrand, prefix = 'Ask your manager'): string {
  return brand.isFallback ? `${prefix}.` : `${prefix} at ${brand.name}.`;
}

/** The browser tab and Home Screen title: "Pay stubs · MoSa's employee app". */
export function pageTitle(title: string, brand: EmployeeBrand): string {
  return brand.isFallback ? `${title} · ${FALLBACK_BRAND_NAME}` : `${title} · ${possessive(brand.name)} employee app`;
}
