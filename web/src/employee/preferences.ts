// The only things the employee app keeps in browser storage: whether this
// device hides amounts, and whether the one-time explainer has been shown.
// Never pay data. Storage can be blocked (private mode, cleared site data, a
// browser policy that makes even reading `window.localStorage` throw), so
// storage is looked up inside each try and every failure quietly falls back to
// hiding amounts (fail closed).
export const HIDE_AMOUNTS_KEY = 'employee-app:hide-amounts';
export const HIDE_AMOUNTS_EXPLAINED_KEY = 'employee-app:hide-amounts-explained';

type StorageLookup = () => Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> | undefined;

const browserStorage: StorageLookup = () => globalThis.localStorage;

/** Masked by default on every device; only an explicit `'false'` shows amounts. */
export function readHideAmounts(storage: StorageLookup = browserStorage): boolean {
  try {
    return storage()?.getItem(HIDE_AMOUNTS_KEY) !== 'false';
  } catch {
    return true;
  }
}

export function writeHideAmounts(hidden: boolean, storage: StorageLookup = browserStorage): void {
  try {
    storage()?.setItem(HIDE_AMOUNTS_KEY, hidden ? 'true' : 'false');
  } catch {
    // The choice then lasts until the page reloads.
  }
}

export function readHideAmountsExplained(storage: StorageLookup = browserStorage): boolean {
  try {
    return storage()?.getItem(HIDE_AMOUNTS_EXPLAINED_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeHideAmountsExplained(storage: StorageLookup = browserStorage): void {
  try {
    storage()?.setItem(HIDE_AMOUNTS_EXPLAINED_KEY, 'true');
  } catch {
    // Storage blocked: the explainer still shows at most once this session.
  }
}
