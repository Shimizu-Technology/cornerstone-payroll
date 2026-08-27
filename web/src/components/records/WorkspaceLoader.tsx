import type { ReactElement } from 'react';
import { LoaderCircle } from 'lucide-react';

interface WorkspaceLoaderProps {
  label: string;
  minHeightClassName?: string;
}

export function WorkspaceLoader({ label, minHeightClassName = 'min-h-[420px]' }: WorkspaceLoaderProps): ReactElement {
  return (
    <div className={`flex ${minHeightClassName} items-center justify-center px-6 py-12`} role="status">
      <span className="inline-flex items-center gap-3 rounded-full border border-neutral-200 bg-white px-4 py-2 text-sm font-semibold text-neutral-600 shadow-sm">
        <LoaderCircle className="h-4 w-4 animate-spin text-primary-700" aria-hidden="true" />
        {label}
      </span>
    </div>
  );
}
