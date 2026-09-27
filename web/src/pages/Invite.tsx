import { useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Button } from '@/components/ui/button';

const INVITE_TOKEN_KEY = 'cpr_invite_token';

export function Invite() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const token = params.get('token');

  useEffect(() => {
    if (token) {
      localStorage.setItem(INVITE_TOKEN_KEY, token);
    }
  }, [token]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 px-4 py-6">
      <div className="w-full max-w-md rounded-lg border border-gray-200 bg-white p-5 text-center shadow-sm sm:p-8">
        <h1 className="text-xl font-semibold text-gray-900">Accept Invitation</h1>
        <p className="text-sm text-gray-600 mt-2">
          Continue to sign in to accept your invitation.
        </p>
        <Button className="mt-6 w-full" onClick={() => navigate('/login')}>
          Continue to Login
        </Button>
      </div>
    </div>
  );
}
