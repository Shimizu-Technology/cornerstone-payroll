import { readFileSync } from 'node:fs';
import { renderToStaticMarkup } from 'react-dom/server';
import { expect, it } from 'vitest';
import { Badge } from './badge';

const theme = readFileSync(new URL('../../index.css', import.meta.url), 'utf8');
function luminance(hex: string): number {
  const channels = hex.match(/\w{2}/g)!.map(channel => parseInt(channel, 16) / 255)
    .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}
function token(role: string): number {
  const hex = theme.match(new RegExp(`--color-${role}:\\s*#([0-9a-f]{6})`, 'i'))?.[1];
  expect(hex, `Theme must define ${role}`).toBeTruthy();
  return luminance(hex!);
}
it.each(['default', 'success', 'warning', 'danger', 'info', 'outline'] as const)('%s badge meets normal-text contrast using its actual theme tokens', variant => {
  const markup = renderToStaticMarkup(<Badge variant={variant}>Payroll status</Badge>);
  const foreground = token(markup.match(/text-([a-z]+-\d+)/)![1]);
  const backgroundRole = markup.match(/bg-([a-z]+-\d+)/)?.[1];
  const background = backgroundRole ? token(backgroundRole) : 1;
  expect((Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05)).toBeGreaterThanOrEqual(4.5);
});
