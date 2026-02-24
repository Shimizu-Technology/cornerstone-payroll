import { SignIn } from '@clerk/clerk-react';
import { useAuth } from '@/contexts/AuthContext';
import { Card, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

export function Login() {
  const { isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <p className="text-gray-500">Loading...</p>
      </div>
    );
  }

  // Clerk not configured in frontend
  if (!clerkPubKey) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <Card className="max-w-md w-full">
          <CardHeader className="text-center">
            <CardTitle className="text-xl">Cornerstone Payroll</CardTitle>
            <CardDescription>
              Clerk is not configured in `web/.env`. Add `VITE_CLERK_PUBLISHABLE_KEY` to sign in.
            </CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-gray-900">Cornerstone Payroll</h1>
          <p className="text-gray-500 mt-1">Sign in to manage payroll</p>
        </div>
        <SignIn
          routing="hash"
          appearance={{
            elements: {
              rootBox: 'mx-auto',
              card: 'shadow-lg',
            },
          }}
        />
      </div>
    </div>
  );
}
