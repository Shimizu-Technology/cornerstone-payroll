export type DeviceClass = 'Desktop' | 'Phone' | 'Tablet' | 'Unknown';

export interface UserAgentPresentation {
  browser: string;
  platform: string;
  operatingSystem: string;
  deviceClass: DeviceClass;
  summary: string;
}

function browserName(userAgent: string): string {
  if (/Edg(?:iOS|A)?\//i.test(userAgent)) return 'Microsoft Edge';
  if (/OPR\//i.test(userAgent)) return 'Opera';
  if (/CriOS\//i.test(userAgent)) return 'Chrome';
  if (/FxiOS\//i.test(userAgent)) return 'Firefox';
  if (/Chrome\//i.test(userAgent) && !/Chromium\//i.test(userAgent)) return 'Chrome';
  if (/Firefox\//i.test(userAgent)) return 'Firefox';
  if (/Version\/[\d.]+.*Safari\//i.test(userAgent)) return 'Safari';
  return 'Unknown browser';
}

function platformDetails(userAgent: string): { platform: string; operatingSystem: string; deviceClass: DeviceClass } {
  if (/iPhone/i.test(userAgent)) return { platform: 'iPhone', operatingSystem: 'iOS', deviceClass: 'Phone' };
  if (/iPad/i.test(userAgent)) return { platform: 'iPad', operatingSystem: 'iPadOS', deviceClass: 'Tablet' };
  if (/Android/i.test(userAgent)) {
    const isPhone = /Mobile/i.test(userAgent);
    return { platform: 'Android', operatingSystem: 'Android', deviceClass: isPhone ? 'Phone' : 'Tablet' };
  }
  if (/Windows NT/i.test(userAgent)) return { platform: 'Windows', operatingSystem: 'Windows', deviceClass: 'Desktop' };
  if (/Macintosh|Mac OS X/i.test(userAgent)) return { platform: 'macOS', operatingSystem: 'macOS', deviceClass: 'Desktop' };
  if (/CrOS/i.test(userAgent)) return { platform: 'ChromeOS', operatingSystem: 'ChromeOS', deviceClass: 'Desktop' };
  if (/Linux/i.test(userAgent)) return { platform: 'Linux', operatingSystem: 'Linux', deviceClass: 'Desktop' };
  return { platform: 'Unknown platform', operatingSystem: 'Unknown', deviceClass: 'Unknown' };
}

export function presentUserAgent(value?: string | null): UserAgentPresentation {
  const userAgent = value?.trim() || '';
  if (!userAgent) {
    return {
      browser: 'Unknown browser',
      platform: 'Unknown platform',
      operatingSystem: 'Unknown',
      deviceClass: 'Unknown',
      summary: 'Unknown browser/device',
    };
  }

  const browser = browserName(userAgent);
  const platform = platformDetails(userAgent);
  const browserLabel = browser === 'Unknown browser' && platform.deviceClass !== 'Unknown'
    ? `${platform.deviceClass === 'Desktop' ? 'Desktop' : 'Mobile'} browser`
    : browser;
  const summary = platform.platform === 'Unknown platform'
    ? browser === 'Unknown browser' ? 'Unknown browser/device' : browser
    : `${browserLabel} on ${platform.platform}`;

  return { browser, summary, ...platform };
}
