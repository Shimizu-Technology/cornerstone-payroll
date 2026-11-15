import { useId, useState } from 'react';
import { columnLetter, type SheetPreviewData } from '@/lib/sheetPreview';
import { cn } from '@/lib/utils';

const NUMERIC_CELL = /^[-(]?\$?[\d,]+(\.\d+)?%?\)?$/;

// One read-only sheet table for every spreadsheet preview: documents, Pay
// Period Files and the workbook beside import review. Tables scroll inside
// their own box so a wide sheet never widens the page.
export function SheetPreview({ data, className, tableClassName }: { data: SheetPreviewData; className?: string; tableClassName?: string }) {
  const [selected, setSelected] = useState(0);
  const baseId = useId();
  const index = Math.min(selected, Math.max(data.sheets.length - 1, 0));
  const sheet = data.sheets[index];
  const notes = [
    data.truncated_sheets && `Showing the first ${data.sheets.length} of ${data.sheet_count} sheets.`,
    sheet?.truncated_rows && `Showing the first ${data.limits.rows} rows with data.`,
    sheet?.truncated_columns && `Showing the first ${data.limits.columns} columns.`,
  ].filter(Boolean);

  if (!sheet) return <p className="p-4 text-sm text-neutral-600">This workbook has no sheets to show.</p>;

  return (
    <div className={cn('flex min-h-0 flex-col', className)}>
      {data.sheets.length > 1 && (
        <div role="tablist" aria-label="Sheets" className="flex shrink-0 gap-1 overflow-x-auto border-b border-neutral-200 px-2 pt-2">
          {data.sheets.map((entry, position) => (
            <button
              key={`${entry.name}-${position}`}
              id={`${baseId}-tab-${position}`}
              type="button"
              role="tab"
              aria-selected={position === index}
              aria-controls={`${baseId}-panel`}
              onClick={() => setSelected(position)}
              className={cn(
                'min-h-11 shrink-0 whitespace-nowrap rounded-t-md border border-b-0 px-3 text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
                position === index ? 'border-neutral-200 bg-white text-neutral-900' : 'border-transparent text-neutral-600 hover:bg-neutral-100'
              )}
            >
              {entry.name || `Sheet ${position + 1}`}
            </button>
          ))}
        </div>
      )}
      {notes.length > 0 && (
        <p role="note" className="shrink-0 border-b border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
          {notes.join(' ')} Download the file to see everything.
        </p>
      )}
      <div
        id={`${baseId}-panel`}
        role={data.sheets.length > 1 ? 'tabpanel' : undefined}
        aria-labelledby={data.sheets.length > 1 ? `${baseId}-tab-${index}` : undefined}
        tabIndex={0}
        className={cn('min-h-0 flex-1 overflow-auto overscroll-contain bg-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-500', tableClassName)}
      >
        {sheet.rows.length === 0 ? (
          <p className="p-4 text-sm text-neutral-600">This sheet is empty.</p>
        ) : (
          <table className="border-separate border-spacing-0 text-xs text-neutral-900">
            <caption className="sr-only">{sheet.name || `Sheet ${index + 1}`}</caption>
            <thead>
              <tr>
                <th scope="col" className="sticky left-0 top-0 z-20 border-b border-r border-neutral-200 bg-neutral-100 px-2 py-1"><span className="sr-only">Row</span></th>
                {Array.from({ length: sheet.columns }, (_, column) => (
                  <th key={column} scope="col" className="sticky top-0 z-10 min-w-16 border-b border-r border-neutral-200 bg-neutral-100 px-2 py-1 text-center font-medium text-neutral-600">
                    {columnLetter(column)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sheet.rows.map((row) => (
                <tr key={row.number}>
                  <th scope="row" className="sticky left-0 z-10 border-b border-r border-neutral-200 bg-neutral-50 px-2 py-1 text-right font-medium tabular-nums text-neutral-600">{row.number}</th>
                  {row.cells.map((cell, column) => (
                    <td
                      key={column}
                      className={cn(
                        'min-w-24 max-w-72 border-b border-r border-neutral-100 px-2 py-1 align-top whitespace-pre-wrap break-words',
                        cell && NUMERIC_CELL.test(cell) && 'whitespace-nowrap text-right tabular-nums'
                      )}
                    >
                      {cell}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
