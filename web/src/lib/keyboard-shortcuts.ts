interface NavigatorWithUserAgentData extends Navigator {
  userAgentData?: {
    platform?: string;
  };
}

function isApplePlatform() {
  if (typeof navigator === 'undefined') return false;

  const userAgentDataPlatform = (navigator as NavigatorWithUserAgentData).userAgentData?.platform;
  const platform = userAgentDataPlatform || navigator.userAgent;

  return /Mac|iPhone|iPad|iPod/i.test(platform);
}

export function platformShortcut(key: string) {
  const parts = key
    .trim()
    .toUpperCase()
    .replace(/[+]/g, ' ')
    .split(/\s+/)
    .filter(Boolean);
  const hasShift = parts.includes('SHIFT') || parts.includes('⇧');
  const hasOption = parts.includes('OPTION') || parts.includes('ALT') || parts.includes('⌥');
  const normalizedKey = parts
    .filter((part) => !['SHIFT', '⇧', 'OPTION', 'ALT', '⌥'].includes(part))
    .join(' ');

  return isApplePlatform()
    ? `${hasShift ? '⇧' : ''}${hasOption ? '⌥' : ''}⌘${normalizedKey}`
    : `Ctrl ${hasOption ? 'Alt ' : ''}${hasShift ? 'Shift ' : ''}${normalizedKey}`;
}
