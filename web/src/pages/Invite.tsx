import { useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
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
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <div className="bg-white p-8 rounded-lg shadow-sm border border-gray-200 max-w-md w-full text-center">
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
