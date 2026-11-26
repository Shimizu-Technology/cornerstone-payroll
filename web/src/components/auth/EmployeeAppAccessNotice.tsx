import { useState, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { Button } from '@/components/ui/button';
import { useAuth } from '@/contexts/AuthContext';

export function EmployeeAppAccessNotice(): ReactElement {
  const { user, signOut } = useAuth();
  const navigate = useNavigate();
  const [working, setWorking] = useState(false);
  const [failed, setFailed] = useState(false);
  const employeeAppUrl = user?.employee_app_url;

  async function leave(): Promise<void> {
    setWorking(true);
    setFailed(false);
    try {
      await signOut({ redirectUrl: '/login' });
      navigate('/login', { replace: true });
    } catch {
      setFailed(true);
      setWorking(false);
    }
  }

  return (
    <main className="grid min-h-dvh place-items-center bg-neutral-50 px-4 py-10">
      <div className="w-full max-w-md space-y-4 rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm sm:p-8">
        <h1 className="text-xl font-semibold text-neutral-950">This sign-in is for your employee app.</h1>
        {employeeAppUrl ? (
          <a href={employeeAppUrl} className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline underline-offset-4">
            Go to your employee app
          </a>
        ) : (
          <p className="text-neutral-700">Open the employee app link from your employer to see your pay.</p>
        )}
        <div>
          <Button type="button" variant="outline" loading={working} onClick={() => { void leave(); }}>Sign out</Button>
        </div>
        {failed && <p role="alert" className="text-sm text-danger-700">Couldn't sign you out. Try again.</p>}
      </div>
    </main>
  );
}
