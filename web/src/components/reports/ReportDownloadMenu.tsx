import { useEffect, useRef, useState } from 'react';
import { ChevronDown, Download, FileSpreadsheet, FileText, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';

export interface ReportDownloadFormat {
  key: string;
  label: string;
  description?: string;
  kind: 'pdf' | 'spreadsheet';
  loading?: boolean;
  onSelect: () => void | Promise<void>;
}

interface ReportDownloadMenuProps {
  formats: ReportDownloadFormat[];
  disabled?: boolean;
  buttonLabel?: string;
  className?: string;
}

export function ReportDownloadMenu({
  formats,
  disabled = false,
  buttonLabel = 'Download',
  className,
}: ReportDownloadMenuProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const busy = formats.some((format) => format.loading);

  useEffect(() => {
    if (!open) return;

    const handlePointerDown = (event: PointerEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };

    window.addEventListener('pointerdown', handlePointerDown);
    window.addEventListener('keydown', handleKeyDown);
    return () => {
      window.removeEventListener('pointerdown', handlePointerDown);
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [open]);

  if (formats.length === 0) return null;

  const runFormat = async (format: ReportDownloadFormat) => {
    setOpen(false);
    await format.onSelect();
  };

  if (formats.length === 1) {
    const format = formats[0];
    return (
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => void runFormat(format)}
        disabled={disabled || busy}
        className={className}
        aria-label={`${buttonLabel} ${format.label}`}
      >
        {format.loading ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Download className="mr-1.5 h-3.5 w-3.5" />}
        {buttonLabel}
      </Button>
    );
  }

  return (
    <div className={`relative ${className ?? ''}`} ref={containerRef}>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => setOpen((current) => !current)}
        disabled={disabled || busy}
        aria-haspopup="menu"
        aria-expanded={open}
      >
        {busy ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <Download className="mr-1.5 h-3.5 w-3.5" />}
        {buttonLabel}
        <ChevronDown className="ml-1 h-3.5 w-3.5" />
      </Button>

      {open && (
        <div
          role="menu"
          className="absolute right-0 top-full z-[120] mt-2 w-64 overflow-hidden rounded-xl border border-neutral-200 bg-white p-1.5 shadow-xl shadow-neutral-900/10"
        >
          {formats.map((format) => (
            <button
              key={format.key}
              type="button"
              role="menuitem"
              onClick={() => void runFormat(format)}
              className="flex w-full items-start gap-3 rounded-lg px-3 py-2.5 text-left transition-colors hover:bg-primary-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300"
            >
              <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-neutral-100 text-neutral-600">
                {format.kind === 'spreadsheet' ? <FileSpreadsheet className="h-4 w-4" /> : <FileText className="h-4 w-4" />}
              </span>
              <span className="min-w-0">
                <span className="block text-sm font-semibold text-neutral-900">{format.label}</span>
                {format.description && <span className="mt-0.5 block text-xs leading-4 text-neutral-500">{format.description}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
