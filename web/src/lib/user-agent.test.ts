import { describe, expect, it } from 'vitest';
import { presentUserAgent } from './user-agent';

describe('presentUserAgent', () => {
  it('presents a desktop Chrome session without claiming an exact device', () => {
    expect(presentUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36')).toEqual({
      browser: 'Chrome',
      platform: 'macOS',
      operatingSystem: 'macOS',
      deviceClass: 'Desktop',
      summary: 'Chrome on macOS',
    });
  });

  it('recognizes Mobile Safari on an iPhone', () => {
    expect(presentUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 Version/18.6 Mobile/15E148 Safari/604.1')).toEqual({
      browser: 'Safari',
      platform: 'iPhone',
      operatingSystem: 'iOS',
      deviceClass: 'Phone',
      summary: 'Safari on iPhone',
    });
  });

  it('recognizes Microsoft Edge on iOS', () => {
    expect(presentUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 EdgiOS/140.0 Mobile/15E148 Safari/605.1.15')).toMatchObject({
      browser: 'Microsoft Edge',
      platform: 'iPhone',
      operatingSystem: 'iOS',
      deviceClass: 'Phone',
      summary: 'Microsoft Edge on iPhone',
    });
  });

  it('uses conservative labels for unknown Android browsers', () => {
    expect(presentUserAgent('ExampleClient/1.0 (Linux; Android 15; Mobile)')).toMatchObject({
      browser: 'Unknown browser',
      platform: 'Android',
      deviceClass: 'Phone',
      summary: 'Mobile browser on Android',
    });
  });

  it('does not invent details for empty or malformed signatures', () => {
    expect(presentUserAgent(null).summary).toBe('Unknown browser/device');
    expect(presentUserAgent('not-a-real-user-agent')).toMatchObject({
      browser: 'Unknown browser',
      platform: 'Unknown platform',
      deviceClass: 'Unknown',
      summary: 'Unknown browser/device',
    });
  });
});
