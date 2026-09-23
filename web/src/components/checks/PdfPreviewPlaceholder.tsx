import { FileCheck2, LoaderCircle } from 'lucide-react';

export function PdfPreviewPlaceholder({ loading }: { loading: boolean }) {
  return (
    <div className="flex h-72 flex-col items-center justify-center border-b border-slate-100 bg-slate-100 px-6 text-center" aria-live="polite">
      {loading ? (
        <LoaderCircle aria-hidden="true" className="h-8 w-8 animate-spin text-blue-700 motion-reduce:animate-none" />
      ) : (
        <FileCheck2 aria-hidden="true" className="h-8 w-8 text-slate-400" />
      )}
      <p className="mt-3 text-sm font-semibold text-slate-800">{loading ? 'Loading and verifying the saved PDF…' : 'Preview is not loaded'}</p>
      <p className="mt-1 max-w-xs text-xs leading-5 text-slate-500">
        {loading ? 'The package will become printable only after its file integrity is verified.' : 'Reload the exact saved package before printing or confirming it.'}
      </p>
    </div>
  );
}
