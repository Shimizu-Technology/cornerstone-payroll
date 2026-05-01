import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Trash2 } from 'lucide-react';
import { normalizeVoucherLineItems, type VoucherLineItemForm } from '@/components/checks/voucherLineItems';

export function VoucherLineItemsEditor({
  items,
  amount,
  onChange,
  className = '',
}: {
  items: VoucherLineItemForm[];
  amount: string;
  onChange: (items: VoucherLineItemForm[]) => void;
  className?: string;
}) {
  const normalized = normalizeVoucherLineItems(items);
  const total = normalized.reduce((sum, item) => sum + item.amount, 0);
  const checkAmount = Number(amount || 0);
  const hasItems = normalized.length > 0;
  const isBalanced = !hasItems || Math.abs(total - checkAmount) <= 0.005;
  const hasIgnoredDetail = items.some(item =>
    Number(item.amount || 0) <= 0 &&
    (item.description.trim() || item.reference_number.trim() || item.service_period.trim())
  );

  const updateItem = (index: number, patch: Partial<VoucherLineItemForm>) => {
    onChange(items.map((item, i) => (i === index ? { ...item, ...patch } : item)));
  };

  const addItem = () => {
    onChange([
      ...items,
      { description: '', reference_number: '', service_period: '', amount: '' },
    ]);
  };

  const removeItem = (index: number) => {
    onChange(items.filter((_, i) => i !== index));
  };

  return (
    <div className={`rounded-xl border border-neutral-200 bg-neutral-50 p-4 ${className}`}>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-sm font-medium text-neutral-900">Voucher detail lines</p>
          <p className="text-xs text-neutral-500">
            Optional line-by-line detail for invoices, tax vouchers, periods, or remittance notes.
          </p>
        </div>
        <Button type="button" variant="outline" size="sm" onClick={addItem}>
          Add line
        </Button>
      </div>

      {items.length > 0 && (
        <div className="mt-3 space-y-3">
          {items.map((item, index) => (
            <div key={item.id || index} className="grid grid-cols-1 gap-2 rounded-lg border border-neutral-200 bg-white p-3 md:grid-cols-12">
              <Input
                className="md:col-span-4"
                placeholder="Description, e.g. May GRT"
                value={item.description}
                onChange={e => updateItem(index, { description: e.target.value })}
              />
              <Input
                className="md:col-span-3"
                placeholder="Reference #"
                value={item.reference_number}
                onChange={e => updateItem(index, { reference_number: e.target.value })}
              />
              <Input
                className="md:col-span-2"
                placeholder="Period"
                value={item.service_period}
                onChange={e => updateItem(index, { service_period: e.target.value })}
              />
              <div className="md:col-span-2">
                <NumericInput
                  placeholder="Amount"
                  min={0.01}
                  fixedDecimalsOnBlur={2}
                  value={item.amount === '' ? null : Number(item.amount)}
                  onValueChange={value => updateItem(index, { amount: value == null ? '' : String(value) })}
                />
              </div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="text-red-500 md:col-span-1"
                onClick={() => removeItem(index)}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
          <div className={`rounded-lg px-3 py-2 text-xs ${isBalanced && !hasIgnoredDetail ? 'bg-white text-neutral-600' : 'bg-red-50 text-red-700'}`}>
            Voucher detail total: {formatCurrency(total)} · Check amount: {formatCurrency(checkAmount)}
            {!isBalanced && ' · totals must match before saving'}
            {hasIgnoredDetail && ' · enter an amount or remove incomplete detail lines'}
          </div>
        </div>
      )}
    </div>
  );
}

function formatCurrency(value: number) {
  return value.toLocaleString(undefined, { style: 'currency', currency: 'USD' });
}
