import type { ReactElement } from 'react';
import { TriangleAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { describeAuthProblem } from '@/lib/authProblem';
import type { AuthProblem } from '@/contexts/AuthContext';

interface AccountAccessNoticeProps {
  problem: AuthProblem;
  onRetry?: () => void;
  onSignOut?: () => void;
  className?: string;
}

export function AccountAccessNotice({ problem, onRetry, onSignOut, className = '' }: AccountAccessNoticeProps): ReactElement {
  const { title, body } = describeAuthProblem(problem);
  return (
    <div role="alert" className={`rounded-2xl border border-amber-300 bg-amber-50 p-4 text-amber-950 ${className}`}>
      <div className="flex items-start gap-3">
        <TriangleAlert aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
        <div className="min-w-0">
          <h2 className="text-base font-semibold">{title}</h2>
          <p className="mt-1 text-sm leading-6">{body}</p>
          <p className="mt-2 break-words text-xs text-amber-900">Detail from the server: {problem.message}</p>
          {(onRetry || onSignOut) && (
            <div className="mt-3 flex flex-col gap-2 sm:flex-row">
              {onRetry && <Button type="button" variant="outline" onClick={onRetry}>Try again</Button>}
              {onSignOut && <Button type="button" variant="outline" onClick={onSignOut}>Sign in with a different account</Button>}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
