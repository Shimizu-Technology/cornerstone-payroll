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
    const faviconUrl = brand.logoUrl ?? icons[0]?.src;
    if (faviconUrl) favicon.href = faviconUrl;

    const touchIcon = document.createElement('link');
    touchIcon.rel = 'apple-touch-icon';
    const touchIconUrl = initialIcon(brand, 180);
    if (touchIconUrl) {
      touchIcon.href = touchIconUrl;
      touchIcon.sizes.add('180x180');
    }

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
      icons,
    })], { type: 'application/manifest+json' }));
    const manifest = document.createElement('link');
    manifest.rel = 'manifest';
    manifest.href = manifestUrl;

    const elements: HTMLElement[] = [theme, appleTitle, manifest];
    if (touchIconUrl || brand.logoUrl) elements.push(touchIcon);
    if (faviconUrl && !isStaging) elements.push(favicon);
    document.head.append(...elements);

    // Keep the square initial unless the logo decodes at square dimensions.
    // Loading the image doesn't need CORS because we only read its dimensions.
    const logo = brand.logoUrl ? new Image() : null;
    if (logo && brand.logoUrl) {
      logo.onload = () => {
        if (logo.naturalWidth > 0 && logo.naturalWidth === logo.naturalHeight) {
          touchIcon.href = logo.src;
          touchIcon.sizes.value = `${logo.naturalWidth}x${logo.naturalHeight}`;
        }
      };
      logo.src = brand.logoUrl;
    }
    return () => {
      if (logo) logo.onload = null;
      elements.forEach(element => element.remove());
      URL.revokeObjectURL(manifestUrl);
    };
  }, [brand, enabled]);
}
