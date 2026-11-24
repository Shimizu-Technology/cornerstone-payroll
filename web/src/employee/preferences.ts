// The only thing the employee app keeps in browser storage: whether this
// device hides amounts. Never pay data. Storage can be blocked (private mode,
// cleared site data, a browser policy that makes even reading
// `window.localStorage` throw), so storage is looked up inside each try and
// every failure quietly means "show amounts".
export const HIDE_AMOUNTS_KEY = 'employee-app:hide-amounts';

type StorageLookup = () => Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> | undefined;

const browserStorage: StorageLookup = () => globalThis.localStorage;

export function readHideAmounts(storage: StorageLookup = browserStorage): boolean {
  try {
    return storage()?.getItem(HIDE_AMOUNTS_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeHideAmounts(hidden: boolean, storage: StorageLookup = browserStorage): void {
  try {
    const store = storage();
    if (hidden) store?.setItem(HIDE_AMOUNTS_KEY, 'true');
    else store?.removeItem(HIDE_AMOUNTS_KEY);
  } catch {
    // The choice then lasts until the page reloads.
  }
}
