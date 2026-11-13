import type { AuthProblem } from '@/contexts/AuthContext';

/** Plain-language reasons for a refused sign-in. The server's own wording stays as a detail. */
export function describeAuthProblem(problem: AuthProblem): { title: string; body: string } {
  const text = problem.message.toLowerCase();
  if (text.includes('inactive') || text.includes('deactivated') || text.includes('disabled')) {
    return {
      title: 'This account is turned off',
      body: 'Cornerstone has turned this login off, so it cannot open payroll or the client portal. Contact Cornerstone to have it turned back on.',
    };
  }
  if (problem.status === 401) {
    return {
      title: 'This sign-in cannot open an account',
      body: 'Either Cornerstone has not set up an account for this email yet, or the account has been turned off. Contact Cornerstone to check, and ask for an invitation if you need one.',
    };
  }
  if (problem.status === 403) {
    return {
      title: 'This account cannot open the workspace yet',
      body: 'You are signed in, but this login does not have access here. Contact Cornerstone to check your access.',
    };
  }
  return {
    title: 'We could not open your account',
    body: 'Something went wrong while loading your account. Try again. If it keeps happening, contact Cornerstone.',
  };
}
