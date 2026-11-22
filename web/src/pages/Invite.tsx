import { Link } from 'react-router';

export function Invite() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 px-4 py-6">
      <div className="w-full max-w-md rounded-lg border border-gray-200 bg-white p-5 text-center shadow-sm sm:p-8">
        <h1 className="text-xl font-semibold text-gray-900">This invitation link has expired</h1>
        <p className="mt-2 text-sm text-gray-600">
          Ask your Payroll administrator to send a new invitation. If your Payroll account is already set up, you can sign in.
        </p>
        <Link
          to="/login"
          className="mt-6 inline-flex min-h-11 items-center rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800 focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
        >
          Go to sign in
        </Link>
      </div>
    </div>
  );
}
