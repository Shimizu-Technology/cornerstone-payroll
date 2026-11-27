import { guamDay } from './contracts';

// "Go paperless?" helpers kept out of paperless.tsx so it exports only components.

/** The step shown once after sign-up or adding access, and from the Home card. */
export const PAPERLESS_PATH = '/go-paperless';

export type DeliveryCardKind = 'pay_statements' | 'w2gu';

// "Not now" on a Home card hides it for this tab only (sessionStorage), per
// employer link. Nothing about the answer itself is stored on the device.
const DISMISS_KEY = 'employee-delivery-cards-hidden';
const hiddenInMemory = new Set<string>();

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function hiddenList(): string[] {
  try {
    const parsed: unknown = JSON.parse(storage()?.getItem(DISMISS_KEY) ?? '[]');
    return Array.isArray(parsed) ? parsed.filter((entry): entry is string => typeof entry === 'string') : [];
  } catch {
    return [];
  }
}

export function deliveryCardHidden(linkId: string, kind: DeliveryCardKind): boolean {
  const key = `${linkId}:${kind}`;
  return hiddenInMemory.has(key) || hiddenList().includes(key);
}

export function hideDeliveryCard(linkId: string, kind: DeliveryCardKind): void {
  const key = `${linkId}:${kind}`;
  hiddenInMemory.add(key);
  try {
    storage()?.setItem(DISMISS_KEY, JSON.stringify([...new Set([...hiddenList(), key])]));
  } catch {
    // Storage blocked: the card stays hidden until the page reloads.
  }
}

/** Tests only: forget cards hidden in memory. */
export function resetHiddenDeliveryCards(): void {
  hiddenInMemory.clear();
}

/**
 * December 1 through January 31 in Guam: when the W-2GU question is worth
 * asking on Home, since forms go out by January 31.
 */
export function inW2GuSeason(now: Date = new Date()): boolean {
  const monthDay = guamDay(now).slice(5);
  return monthDay >= '12-01' || monthDay <= '01-31';
}

/** The tax year whose W-2GU is coming: this year in December, last year in January. */
export function upcomingW2GuYear(now: Date = new Date()): number {
  const [year, month] = guamDay(now).split('-').map(Number);
  return month === 12 ? year : year - 1;
}
