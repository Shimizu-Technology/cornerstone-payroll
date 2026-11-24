import { createContext, useContext, type ComponentType } from 'react';
import { brandFrom, type EmployeeBrand } from './brand';
import type { EmployeeApi, EmployeeLink, EmployeeProblem } from './api';

export const BrandContext = createContext<EmployeeBrand>(brandFrom(null));

export function useBrand(): EmployeeBrand {
  return useContext(BrandContext);
}

export interface EmployeeAuthValue {
  isLoaded: boolean;
  isSignedIn: boolean;
  getToken: () => Promise<string | null>;
  signOut: () => Promise<void>;
  /** The sign-in form. `redirectTo` is the app path to open after signing in. */
  SignInForm: ComponentType<{ redirectTo: string }>;
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
  | { status: 'ready'; link: EmployeeLink }
  | { status: 'problem'; problem: EmployeeProblem };

export interface EmployeeSessionValue {
  state: EmployeeSessionState;
  api: EmployeeApi;
  retry: () => void;
  /** Data screens pass API failures here so a mid-session 404 shows "access ended". */
  reportError: (error: unknown) => void;
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
