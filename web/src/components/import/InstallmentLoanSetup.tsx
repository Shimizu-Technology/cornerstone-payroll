import { useRef, useState, type ChangeEvent } from 'react';
import { Link } from 'react-router';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatCurrency } from '@/lib/utils';
import type { InstallmentLoanSetupOffer } from '@/services/api';

export interface InstallmentLoanFields {
  name: string;
  starting_balance: string;
  payment_amount: string;
  first_deduction_date: string;
}

interface InstallmentLoanSetupProps {
  employeeName: string;
  offer: InstallmentLoanSetupOffer;
  access?: { allowed: boolean; reason: string | null };
  disabled?: boolean;
  onCreate: (fields: InstallmentLoanFields) => Promise<void>;
  onResume: () => Promise<void>;
}

const amount = (value: string | null | undefined) => formatCurrency(Number(value || 0));
const MONEY = /^\d{1,9}(\.\d{1,2})?$/;

// The workbook has an installment Employee Loans doesn't. Staff confirm the
// workbook's figures (or resume a paused loan) without leaving the review.
export function InstallmentLoanSetup({ employeeName, offer, access, disabled = false, onCreate, onResume }: InstallmentLoanSetupProps) {
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fields, setFields] = useState<InstallmentLoanFields>(() => offer.action === 'create'
    ? { name: offer.name, starting_balance: offer.starting_balance, payment_amount: offer.payment_amount, first_deduction_date: offer.first_deduction_date }
    : { name: '', starting_balance: '', payment_amount: '', first_deduction_date: '' });
  const allowed = access?.allowed !== false;

  // A double tap sends one request; the server never duplicates a loan anyway.
  const inFlight = useRef(false);
  const run = async (action: () => Promise<void>) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not set up the loan');
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  const starting = Number(fields.starting_balance);
  const payment = Number(fields.payment_amount);
  const fieldError = !fields.name.trim() ? 'Enter a loan name.'
    : !MONEY.test(fields.starting_balance.trim()) || starting <= 0 ? 'Enter a starting balance greater than zero.'
    : !MONEY.test(fields.payment_amount.trim()) || payment <= 0 ? 'Enter a payment per payroll greater than zero.'
    : payment > starting ? 'The payment per payroll can’t be more than the starting balance.'
    : !fields.first_deduction_date ? 'Choose the first deduction pay date.'
    : null;
  const update = (key: keyof InstallmentLoanFields) => (event: ChangeEvent<HTMLInputElement>) => setFields((current) => ({ ...current, [key]: event.target.value }));

  return (
    <section aria-label={`Installment loan for ${employeeName}`} className="space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-3 text-left text-sm text-amber-950 whitespace-normal">
      {offer.action === 'create' ? (
        <>
          <p className="font-semibold">New installment loan in the workbook</p>
          <p>
            {amount(offer.starting_balance)} starting balance · {amount(offer.payment_amount)} this payroll. Employee Loans has no installment loan for {employeeName}, so it isn’t deducted until it’s set up.
          </p>
        </>
      ) : (
        <>
          <p className="font-semibold">Paused installment loan</p>
          <p>
            {offer.name} is paused in Employee Loans with {amount(offer.current_balance)} left. Resume it so this payroll deducts the installment.
          </p>
        </>
      )}

      {!allowed ? (
        <p className="font-medium">{access?.reason}</p>
      ) : offer.action === 'resume' ? (
        <Button type="button" disabled={disabled || busy} onClick={() => void run(onResume)}>
          {busy ? 'Resuming…' : `Resume ${offer.name}`}
        </Button>
      ) : !editing ? (
        <Button type="button" disabled={disabled || busy} onClick={() => setEditing(true)}>Set up installment loan</Button>
      ) : (
        <form
          className="space-y-3 rounded-lg border border-amber-200 bg-white p-3 text-neutral-900"
          onSubmit={(event) => {
            event.preventDefault();
            if (fieldError) { setError(fieldError); return; }
            void run(() => onCreate({ ...fields, name: fields.name.trim(), starting_balance: fields.starting_balance.trim(), payment_amount: fields.payment_amount.trim() }));
          }}
        >
          <div className="grid gap-3 sm:grid-cols-2">
            <Input label="Loan name" value={fields.name} maxLength={100} onChange={update('name')} disabled={busy} />
            <Input label="First deduction pay date" type="date" value={fields.first_deduction_date} readOnly aria-readonly="true" helperText="This payroll" />
            <Input label="Starting balance" inputMode="decimal" value={fields.starting_balance} onChange={update('starting_balance')} disabled={busy} />
            <Input label="Payment per payroll" inputMode="decimal" value={fields.payment_amount} onChange={update('payment_amount')} disabled={busy} />
          </div>
          <p className="text-xs text-neutral-600">
            From the workbook: {amount(offer.beginning_balance)} beginning balance + {amount(offer.new_amount)} new loan.
            {Number(offer.estimated_ending_balance) > 0 && ` Estimated ending balance ${amount(offer.estimated_ending_balance)}.`}
          </p>
          <p className="text-xs font-medium text-amber-900">Changing these amounts from the workbook will show a balance mismatch on the next review.</p>
          <div className="flex flex-col gap-2 sm:flex-row">
            <Button type="submit" disabled={disabled || busy}>{busy ? 'Creating loan…' : 'Create loan'}</Button>
            <Button type="button" variant="outline" disabled={busy} onClick={() => { setEditing(false); setError(null); }}>Cancel</Button>
          </div>
        </form>
      )}

      {error && <p role="alert" className="font-medium text-danger-700">{error}</p>}
      <Link to="/employee-loans" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center font-medium text-primary-700 underline">
        Open Employee Loans (new tab)
      </Link>
    </section>
  );
}
