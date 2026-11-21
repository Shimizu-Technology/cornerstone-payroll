import { Input } from '@/components/ui/input';
import { formatContinuingNumber, readNumberWidth } from '@/lib/invoiceNumber';

/** "Digits in invoice number" with its hint, a live example and an inline error. */
export function InvoiceNumberWidthField({ value, nextNumber, onChange }: { value: string; nextNumber: number; onChange: (value: string) => void }) {
  const width = readNumberWidth(value);
  return (
    <div className="sm:col-span-2">
      <label htmlFor="invoice-number-width" className="text-sm">Digits in invoice number</label>
      <Input id="invoice-number-width" type="number" min="1" max="12" step="1" inputMode="numeric"
        aria-invalid={width.error ? true : undefined}
        aria-describedby={`invoice-number-width-hint ${width.error ? 'invoice-number-width-error' : 'invoice-number-width-example'}`}
        placeholder="Leave blank for no leading zeros" value={value} onChange={(event) => onChange(event.target.value)} />
      <p id="invoice-number-width-hint" className="mt-1 text-xs text-neutral-600">Adds leading zeros so numbers line up with your past invoices: 5 digits turns 7055 into 07055. Issued invoices keep their numbers.</p>
      {width.error ? (
        <p id="invoice-number-width-error" role="alert" className="mt-1 text-sm font-semibold text-red-800">{width.error}</p>
      ) : (
        <p id="invoice-number-width-example" aria-live="polite" className="mt-1 text-sm font-semibold text-neutral-900">
          Next invoice: {formatContinuingNumber(nextNumber || 1, width.value)}
        </p>
      )}
    </div>
  );
}
