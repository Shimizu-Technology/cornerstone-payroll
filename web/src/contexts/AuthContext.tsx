import { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { useAuth as useClerkAuth } from '@clerk/clerk-react';
import { ApiError, authApi, setAuthToken } from '@/services/api';

interface User {
  id: number;
  email: string;
  name: string;
  role: string;
  company_id: number;
  company_name: string;
}

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  isAdmin: boolean;
  isManager: boolean;
  signOut: () => Promise<void>;
  refreshUser: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

// Dev mode bypass — when VITE_CLERK_PUBLISHABLE_KEY is not set
const isDevMode = !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;
const authEnabled = import.meta.env.VITE_AUTH_ENABLED === 'true';

function DevAuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    // If auth is enabled but Clerk is not configured, don't hammer /auth/me.
    // The UI should route to /login and show the missing configuration state.
    if (authEnabled) {
      setUser(null);
      setIsLoading(false);
      return;
    }

    // In dev mode, just fetch /auth/me without a token
    authApi.me()
      .then((res) => setUser(res.user as any))
      .catch(() => setUser(null))
      .finally(() => setIsLoading(false));
  }, []);

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isAuthenticated: !!user,
        isAdmin: user?.role === 'admin',
        isManager: user?.role === 'manager' || user?.role === 'admin',
        signOut: async () => setUser(null),
        refreshUser: async () => {
          const res = await authApi.me();
          setUser(res.user as any);
        },
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
  const { isSignedIn, isLoaded, getToken, signOut: clerkSignOut } = useClerkAuth();
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [backendUnauthorized, setBackendUnauthorized] = useState(false);

  const refreshUser = useCallback(async () => {
    if (!isSignedIn) {
      setUser(null);
      setBackendUnauthorized(false);
      setIsLoading(false);
      return;
    }

    if (backendUnauthorized) {
      setIsLoading(false);
      return;
    }

    try {
      const token = await getToken();
      if (token) {
        // Set token for API calls
        setAuthToken(token);
      }

      const res = await authApi.me();
      setUser(res.user as any);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        // Clerk session exists but backend rejected user (e.g. not provisioned/invited).
        // Sign out locally to prevent redirect/auth polling loops.
        setBackendUnauthorized(true);
        setAuthToken(null);
        await clerkSignOut();
      } else {
        console.error('Failed to load user:', err);
      }
      setUser(null);
    } finally {
      setIsLoading(false);
    }
  }, [backendUnauthorized, isSignedIn, getToken, clerkSignOut]);

  // Refresh user when Clerk auth state changes
  useEffect(() => {
    if (isLoaded) {
      refreshUser();
    }
  }, [isLoaded, isSignedIn, refreshUser]);

  // Keep token fresh
  useEffect(() => {
    if (!isSignedIn) return;

    const interval = setInterval(async () => {
      const token = await getToken();
      if (token) {
        setAuthToken(token);
      }
    }, 50000); // Refresh every 50s

    return () => clearInterval(interval);
  }, [isSignedIn, getToken]);

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading: !isLoaded || isLoading,
        isAuthenticated: !!user && isSignedIn === true,
        isAdmin: user?.role === 'admin',
        isManager: user?.role === 'manager' || user?.role === 'admin',
        signOut: async () => {
          setUser(null);
          await clerkSignOut();
        },
        refreshUser,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  if (isDevMode) {
    return <DevAuthProvider>{children}</DevAuthProvider>;
  }
  return <ClerkAuthProvider>{children}</ClerkAuthProvider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
