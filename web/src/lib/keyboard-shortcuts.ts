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
  const normalizedKey = key.trim().toUpperCase();
  return isApplePlatform() ? `⌘${normalizedKey}` : `Ctrl ${normalizedKey}`;
}
