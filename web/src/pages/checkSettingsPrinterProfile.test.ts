import { describe, expect, it } from 'vitest';
import { selectedPrinterProfileLockVersion } from './checkSettingsPrinterProfile';

describe('selectedPrinterProfileLockVersion', () => {
  it('uses the refreshed version after a calibration save before the profile list reloads', () => {
    expect(selectedPrinterProfileLockVersion(8, 3, 8, 3)).toBe(3);
    expect(selectedPrinterProfileLockVersion(8, 4, 8, 3)).toBe(4);
  });

  it('uses the newly selected profile version after switching profiles', () => {
    expect(selectedPrinterProfileLockVersion(8, 4, 9, 1)).toBe(1);
  });
});
