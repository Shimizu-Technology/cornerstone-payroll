import { useEffect } from 'react';
import { isStaging } from '@/lib/staging';
import { accentPair, type EmployeeBrand } from './brand';

function initialIcon(brand: EmployeeBrand, size: number): string | null {
  if (typeof CanvasRenderingContext2D === 'undefined') return null;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const context = canvas.getContext('2d');
  if (!context) return null;
  const { accent, ink } = accentPair(brand.decoration);
  context.fillStyle = accent;
  context.fillRect(0, 0, size, size);
  context.fillStyle = ink;
  context.font = `bold ${size * 0.52}px system-ui, sans-serif`;
  context.textAlign = 'center';
  context.textBaseline = 'middle';
  context.fillText(brand.monogram, size / 2, size / 2, size * 0.78);
  return canvas.toDataURL('image/png');
}

export function useEmployeeInstallMetadata(brand: EmployeeBrand, enabled: boolean): void {
  useEffect(() => {
    if (!enabled || typeof URL.createObjectURL !== 'function') return;

    const shortName = brand.appName ?? brand.name;
    const theme = document.createElement('meta');
    theme.name = 'theme-color';
    theme.content = brand.decoration;
    const appleTitle = document.createElement('meta');
    appleTitle.name = 'apple-mobile-web-app-title';
    appleTitle.content = shortName;

    const icons = [192, 512].flatMap(size => {
      const src = initialIcon(brand, size);
      return src ? [{ src, sizes: `${size}x${size}`, type: 'image/png' }] : [];
    });
    const favicon = document.createElement('link');
    favicon.rel = 'icon';
    const touchIcon = document.createElement('link');
    touchIcon.rel = 'apple-touch-icon';
    const iconUrl = brand.logoUrl ?? icons[0]?.src;
    if (iconUrl) favicon.href = touchIcon.href = iconUrl;

    // A blob has no directory for resolving relative URLs. Always launch
    // the employee host's root, including when installed from a deep link.
    const root = `${window.location.origin}/`;
    const manifestUrl = URL.createObjectURL(new Blob([JSON.stringify({
      id: root,
      name: brand.name,
      short_name: shortName,
      start_url: root,
      scope: root,
      display: 'standalone',
      theme_color: brand.decoration,
      background_color: brand.actionTint,
      icons: brand.logoUrl ? [{ src: brand.logoUrl }, ...icons] : icons,
    })], { type: 'application/manifest+json' }));
    const manifest = document.createElement('link');
    manifest.rel = 'manifest';
    manifest.href = manifestUrl;

    const elements: HTMLElement[] = [theme, appleTitle, manifest];
    if (iconUrl) elements.push(touchIcon);
    if (iconUrl && !isStaging) elements.push(favicon);
    document.head.append(...elements);
    return () => {
      elements.forEach(element => element.remove());
      URL.revokeObjectURL(manifestUrl);
    };
  }, [brand, enabled]);
}
