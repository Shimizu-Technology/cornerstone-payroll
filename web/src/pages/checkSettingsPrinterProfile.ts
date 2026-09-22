export function selectedPrinterProfileLockVersion(
  savedProfileId: number | null | undefined,
  savedProfileLockVersion: number | null | undefined,
  selectedProfileId: number | null,
  selectedProfileLockVersion: number | null | undefined
): number | null {
  if (savedProfileId === selectedProfileId) {
    return savedProfileLockVersion ?? selectedProfileLockVersion ?? null;
  }

  return selectedProfileLockVersion ?? null;
}
