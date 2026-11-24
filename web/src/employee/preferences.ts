// The only thing the employee app keeps in browser storage: whether this
// device hides amounts. Never pay data. Storage can be blocked (private mode,
// cleared site data), so every read and write fails quietly to "show amounts".
export const HIDE_AMOUNTS_KEY = 'employee-app:hide-amounts';

export function readHideAmounts(storage: Pick<Storage, 'getItem'> | undefined = globalThis.localStorage): boolean {
  try {
    return storage?.getItem(HIDE_AMOUNTS_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeHideAmounts(hidden: boolean, storage: Pick<Storage, 'setItem' | 'removeItem'> | undefined = globalThis.localStorage): void {
  try {
    if (hidden) storage?.setItem(HIDE_AMOUNTS_KEY, 'true');
    else storage?.removeItem(HIDE_AMOUNTS_KEY);
  } catch {
    // The choice then lasts until the page reloads.
  }
}
