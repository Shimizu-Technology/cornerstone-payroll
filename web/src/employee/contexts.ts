import { createContext, useContext, type ComponentType } from 'react';
import { brandFrom, type EmployeeBrand } from './brand';
import type { EmployeeApi, EmployeeLink, EmployeeProblem } from './api';
import type { EmployeeContextInfo } from './contracts';

export const BrandContext = createContext<EmployeeBrand>(brandFrom(null));

export function useBrand(): EmployeeBrand {
  return useContext(BrandContext);
}

export interface EmployeeAuthValue {
  isSignedIn: boolean;
  /** `fresh` skips the token cache, so a reverification that just finished counts. */
  getToken: (options?: { fresh?: boolean }) => Promise<string | null>;
  signOut: () => Promise<void>;
  /** The sign-in form. `redirectTo` is the app path to open after signing in. */
  SignInForm: ComponentType<{ redirectTo: string }>;
  /** Clerk's sign-up, opened from the invitation link the API returns. `redirectTo` opens after. */
  SignUpForm: ComponentType<{ redirectTo: string }>;
  /**
   * Runs a change behind step-up. When `attempt` throws StepUpRequiredError,
   * this asks the person to confirm it's them (Clerk reverification at the
   * level the API names: a password or email code while two-step sign-in is
   * off, the second step once REQUIRE_MFA is on), then runs `attempt` again.
   * Throws StepUpCancelledError if they close the prompt.
   */
  stepUp: <T>(attempt: () => Promise<T>) => Promise<T>;
  /**
   * Opens the account settings where two-step sign-in is set up (Clerk's user
   * profile) over the current screen, so a form in progress keeps its input.
   */
  openAccountSettings: () => void;
  /** The account settings themselves, embedded on the Sign-in & security page (/security). */
  AccountSecurityPanel: ComponentType;
  /** Development preview only: signs in without Clerk. */
  previewSignIn?: () => void;
}

export interface HideAmountsValue {
  hidden: boolean;
  setHidden: (hidden: boolean) => void;
}

/** "Hide amounts": every amount on screen shows as "$•••" while this is on. */
export const HideAmountsContext = createContext<HideAmountsValue>({ hidden: false, setHidden: () => undefined });

export function useHideAmounts(): HideAmountsValue {
  return useContext(HideAmountsContext);
}

export const EmployeeAuthContext = createContext<EmployeeAuthValue | null>(null);

export function useEmployeeAuth(): EmployeeAuthValue {
  const value = useContext(EmployeeAuthContext);
  if (!value) throw new Error('useEmployeeAuth needs an employee auth provider');
  return value;
}

export type EmployeeSessionState =
  | { status: 'loading' }
  /** More than one employer on a shared host: the person picks one. */
  | { status: 'choose'; links: EmployeeLink[] }
  | { status: 'ready'; link: EmployeeLink; links: EmployeeLink[]; info: EmployeeContextInfo }
  | { status: 'problem'; problem: EmployeeProblem };

export interface EmployeeSessionValue {
  state: EmployeeSessionState;
  api: EmployeeApi;
  retry: () => void;
  /** Data screens pass API failures here so a mid-session 404 shows "access ended". */
  reportError: (error: unknown) => void;
  /** Opens one employer's pay (the picker, or "Switch employer"). Null goes back to the picker. */
  chooseLink: (linkId: string | null) => void;
  /** The open link is a former job: past pay only, no next payday, nothing can change. */
  isFormer: boolean;
  /** A Cornerstone admin's view-only "Sign in as" (M4-9): nothing can change, whatever the job's status. */
  isViewOnly: boolean;
  /** Either of the two: changes are off. */
  readOnly: boolean;
  /** Session memory for data screens. Cleared on sign-out, reload and employer switch; never stored on the device. */
  memory: Map<string, unknown>;
}

/** The open session. Only screens inside the ready shell use this. */
export function useReadySession(): EmployeeSessionValue & { state: Extract<EmployeeSessionState, { status: 'ready' }> } {
  const session = useEmployeeSession();
  if (session.state.status !== 'ready') throw new Error('useReadySession needs an open session');
  return session as EmployeeSessionValue & { state: Extract<EmployeeSessionState, { status: 'ready' }> };
}

export const EmployeeSessionContext = createContext<EmployeeSessionValue | null>(null);

export function useEmployeeSession(): EmployeeSessionValue {
  const value = useContext(EmployeeSessionContext);
  if (!value) throw new Error('useEmployeeSession needs EmployeeSessionProvider');
  return value;
}

export interface SignOutValue {
  /** Signs out and resolves true, or shows "Couldn't sign you out" and resolves false. */
  signOut: () => Promise<boolean>;
}

export const SignOutContext = createContext<SignOutValue | null>(null);
