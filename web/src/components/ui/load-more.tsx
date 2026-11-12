import { ChevronDown } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

interface LoadMoreFooterProps {
  shown: number;
  total: number;
  noun: string;
  hasMore: boolean;
  loading: boolean;
  error?: string | null;
  onLoadMore: () => void;
  className?: string;
}

// Footer for lists the API returns in capped pages. It states how many rows are
// on screen out of the server total and loads the next page on request.
export function LoadMoreFooter({ shown, total, noun, hasMore, loading, error, onLoadMore, className }: LoadMoreFooterProps): React.ReactElement | null {
  if (!hasMore && !error) return null;

  return (
    <div className={cn('flex flex-col items-center gap-3 border-t border-neutral-200 px-4 py-4 text-center', className)}>
      <p className="text-sm text-neutral-600" aria-live="polite">
        Showing <span className="font-medium text-neutral-900">{shown.toLocaleString()}</span> of{' '}
        <span className="font-medium text-neutral-900">{total.toLocaleString()}</span> {noun}
      </p>
      {error && <p className="text-sm text-danger-700" role="alert">{error}</p>}
      <Button className="min-h-11" variant="outline" onClick={onLoadMore} disabled={loading}>
        <ChevronDown className="mr-2 h-4 w-4" aria-hidden="true" />
        {loading ? `Loading more ${noun}…` : error ? 'Try again' : `Load more ${noun}`}
      </Button>
    </div>
  );
}
