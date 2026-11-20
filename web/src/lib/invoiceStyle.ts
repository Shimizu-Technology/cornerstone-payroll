import type { InvoiceTheme } from '@/services/api';

export const INVOICE_THEMES: { id: InvoiceTheme; name: string; blurb: string; accent: string }[] = [
  { id: 'classic', name: 'Classic', blurb: 'Familiar layout, like most accounting software', accent: '#1F4E79' },
  { id: 'modern', name: 'Modern', blurb: 'Big amount due, lots of white space', accent: '#0F766E' },
  { id: 'professional', name: 'Professional', blurb: 'Centered letterhead, serif type', accent: '#6B2737' },
  { id: 'banner', name: 'Banner', blurb: 'Colored header band with your logo', accent: '#1E40AF' },
];

export const SWATCHES = ['#1F4E79', '#0F766E', '#6B2737', '#1E40AF', '#7C2D12', '#334155'];

export function themeDefaultAccent(theme: InvoiceTheme): string {
  return (INVOICE_THEMES.find((entry) => entry.id === theme) || INVOICE_THEMES[0]).accent;
}

// "#1f4e79", "1F4E79" and " #1F4E79 " all become "#1F4E79"; anything else is null.
export function normalizeHex(value: string): string | null {
  const text = value.trim().toUpperCase();
  const withHash = text.startsWith('#') ? text : `#${text}`;
  return /^#[0-9A-F]{6}$/.test(withHash) ? withHash : null;
}

function luminance(hex: string): number {
  const channels = (hex.replace('#', '').match(/../g) || []).map((pair) => {
    const value = parseInt(pair, 16) / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

export function contrastRatio(first: string, second: string): number {
  const [lighter, darker] = [luminance(first), luminance(second)].sort((a, b) => b - a);
  return (lighter + 0.05) / (darker + 0.05);
}

// Same rule as the PDF: white when it reaches 4.5:1 on the accent, otherwise black.
export function textOnAccent(accent: string): '#FFFFFF' | '#000000' {
  return contrastRatio(accent, '#FFFFFF') >= 4.5 ? '#FFFFFF' : '#000000';
}

// Same rule as the PDF monogram: first letters of the first two words.
export function initialsFor(name: string): string {
  const words = name.match(/[\p{L}\p{N}]+/gu) || [];
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return words.slice(0, 2).map((word) => word[0]).join('').toUpperCase() || '?';
}
