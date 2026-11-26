import type { KeyboardEvent, ReactElement } from 'react';
import { Link } from 'react-router';
import { AlertCircle, AlertTriangle, Check, Save, ShieldCheck } from 'lucide-react';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { formatPhone } from '@/lib/display-phone';
import {
  CONTACT_FIELDS,
  FIELD_LABELS,
  baselineFromEmployee,
  type ContactDraft,
  type ContactField,
  type RowConflictState,
  type RowSaveState,
} from '@/lib/employee-contact-editor';
import { cn } from '@/lib/utils';
import type { ContactEmployee, EmployeeContactWarning } from '@/types';

// The contact editor shared by the Contact details grid and the employee
// page's Contact card. Both save through the same employee update endpoint,
// so the server's validator, email-change safeguards and stale-edit guard
// (row_revision + baseline_values) apply to every save.

function gridInputClass(extra = '', invalid = false): string {
  return cn(
    'block h-11 w-full rounded-lg border bg-white py-2 text-base text-neutral-900 lg:h-9 lg:text-sm shadow-xs transition-[border-color,background-color,color,box-shadow] duration-150 ease-out placeholder:text-neutral-400 focus-visible:outline-none focus-visible:ring-2 disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500',
    invalid
      ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200'
      : 'border-neutral-300 focus-visible:border-primary-400 focus-visible:ring-primary-200',
    extra,
  );
}

export function ContactValue({ value, className }: { value: string | null | undefined; className?: string }): ReactElement {
  return value?.trim()
    ? <span className={cn('text-neutral-900', className)}>{value}</span>
    : <span className="text-neutral-400">Not added yet</span>;
}

export function AddressValue({ employee }: { employee: ContactEmployee }): ReactElement {
  const street = [employee.address_line1, employee.address_line2].map((part) => part?.trim()).filter(Boolean).join(', ');
  const cityLine = [employee.city?.trim(), [employee.state?.trim(), employee.zip?.trim()].filter(Boolean).join(' ')].filter(Boolean).join(', ');
  // A state on its own (every record defaults to GU) isn't an address yet.
  if (!street && !employee.city?.trim() && !employee.zip?.trim()) return <span className="text-neutral-400">Not added yet</span>;
  return (
    <span className="block text-neutral-900">
      {street && <span className="block">{street}</span>}
      {cityLine && <span className="block">{cityLine}</span>}
    </span>
  );
}

// Email invites need a unique address, so keep saying so after the row
// closes: from the save's warning, or the row's status after a reload.
export function SharedEmailNote({ employee, warnings }: { employee: ContactEmployee; warnings: EmployeeContactWarning[] }): ReactElement | null {
  const warning = warnings.find((item) => item.code === 'shared_company_email');
  if (!employee.email?.trim() || (!warning && employee.contact_details_status?.email_issue !== 'shared_with_coworker')) return null;
  return (
    <span role="status" className="mt-1 flex items-start gap-1 text-xs text-warning-800">
      <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning-700" aria-hidden="true" />
      <span>{warning?.message ?? 'Another employee uses this email. Email invites need a unique address.'}</span>
    </span>
  );
}

export interface EditorFieldProps {
  label: string;
  ariaLabel: string;
  value: string;
  disabled: boolean;
  errors: string[];
  onChange: (value: string) => void;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
  type?: 'text' | 'email' | 'tel';
  placeholder?: string;
  maxLength?: number;
  hint?: string;
  inputClassName?: string;
  className?: string;
}

export function EditorField({
  label, ariaLabel, value, disabled, errors, onChange, onKeyDown, type = 'text', placeholder, maxLength, hint, inputClassName, className,
}: EditorFieldProps): ReactElement {
  return (
    <label className={cn('block', className)}>
      <span className="text-xs font-medium text-neutral-700">{label}</span>
      <input
        type={type}
        aria-label={ariaLabel}
        value={value}
        disabled={disabled}
        placeholder={placeholder}
        maxLength={maxLength}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={onKeyDown}
        className={gridInputClass(cn('mt-1 px-2', inputClassName), errors.length > 0)}
      />
      {errors.map((message) => (
        <span key={message} role="alert" className="mt-1 block text-xs text-danger-700">{message}</span>
      ))}
      {hint && errors.length === 0 && <span className="mt-1 block text-xs text-neutral-500">{hint}</span>}
    </label>
  );
}

export function RowConflictBanner({
  conflict,
  saving,
  onKeep,
  onDiscard,
}: {
  conflict: RowConflictState;
  saving: boolean;
  onKeep: () => void;
  onDiscard: () => void;
}): ReactElement {
  const fieldsToShow = conflict.conflictingFields.filter(
    (field): field is ContactField => CONTACT_FIELDS.includes(field as ContactField),
  );
  const serverValues = baselineFromEmployee(conflict.serverEmployee);
  const displayValue = (field: ContactField, value?: string): string =>
    (field === 'phone' ? formatPhone(value) : value) || '(blank)';

  return (
    <div role="alert" className="mt-2 rounded-lg border border-warning-300 bg-warning-50 p-4 text-xs text-warning-950">
      <p className="flex items-start gap-2 font-semibold">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
        <span>Someone else updated this employee while you were editing.</span>
      </p>
      {fieldsToShow.length > 0 ? (
        <ul className="mt-2 space-y-2 rounded-md border border-warning-200 bg-white/80 p-2 text-neutral-800">
          {fieldsToShow.map((field) => (
            <li key={field} className="break-words leading-relaxed">
              <strong>{FIELD_LABELS[field]}:</strong> Someone else changed this to{' '}
              <span className="break-all font-mono font-medium text-neutral-950">{displayValue(field, serverValues[field])}</span>. Keep yours (
              <span className="break-all font-mono font-medium text-neutral-950">{displayValue(field, conflict.userChanges[field])}</span>) or use theirs?
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-1 text-warning-900">Keep yours or use theirs?</p>
      )}
      <div className="mt-2 flex flex-wrap gap-2">
        <Button size="sm" variant="primary" disabled={saving} loading={saving} loadingLabel="Saving..." onClick={onKeep}>
          Keep yours
        </Button>
        <Button size="sm" variant="outline" disabled={saving} onClick={onDiscard}>
          Use theirs
        </Button>
      </div>
    </div>
  );
}

export function RowInlineFeedback({
  employee,
  state,
  field,
  hidePrimaryFieldError = false,
  canEdit,
  onToggleSamePerson,
  onConfirmAndSave,
}: {
  employee: ContactEmployee;
  state: RowSaveState;
  field: 'email' | 'phone';
  hidePrimaryFieldError?: boolean;
  canEdit: boolean;
  onToggleSamePerson: (checked: boolean) => void;
  onConfirmAndSave: () => void;
}): ReactElement {
  const fieldErrors = state.fieldErrors[field] ?? [];
  const fieldWarnings = state.warnings.filter((warning) => warning.field === field);

  return (
    <div className="space-y-2">
      {!hidePrimaryFieldError && !state.samePersonRequired && fieldErrors.map((msg) => (
        <p key={msg} role="alert" className="mt-1 flex items-start gap-1 text-xs text-danger-700">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
          <span>{msg}</span>
        </p>
      ))}

      {field === 'email' && state.samePersonRequired && (
        <div role="alert" className="mt-2 rounded-lg border border-warning-300 bg-warning-50 p-2 text-xs text-warning-950">
          <p className="flex items-start gap-2 font-medium">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
            <span>{fieldErrors[0] || `This email belongs to an existing payroll login for ${employee.first_name} ${employee.last_name}.`}</span>
          </p>
          <label className="mt-2 flex cursor-pointer items-start gap-2">
            <input
              type="checkbox"
              checked={state.samePersonChecked}
              disabled={!canEdit || state.saving}
              onChange={(event) => onToggleSamePerson(event.target.checked)}
              className="mt-0.5 h-4 w-4 rounded border-warning-400 text-primary-700 focus:ring-primary-500"
            />
            <span className="font-medium text-neutral-900">
              Yes, this is {employee.first_name} {employee.last_name}&apos;s own email
            </span>
          </label>
          <div className="mt-2">
            <Button
              size="sm"
              disabled={!canEdit || !state.samePersonChecked || state.saving}
              loading={state.saving}
              loadingLabel="Saving..."
              onClick={onConfirmAndSave}
            >
              Confirm and save
            </Button>
          </div>
        </div>
      )}

      {fieldWarnings.map((warning) => (
        <p key={`${warning.code}-${warning.message}`} role="status" className="mt-1 flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 px-2 py-2 text-xs text-warning-900">
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning-700" aria-hidden="true" />
          <span>{warning.message}</span>
        </p>
      ))}
    </div>
  );
}

export function ContactSaveResult({ requestId }: { requestId?: number }) {
  if (requestId) {
    return <Link className="text-primary-700 underline" to={`/change-requests?request_id=${requestId}`}>Address sent for review</Link>;
  }
  return <><Check className="h-3.5 w-3.5" aria-hidden="true" />Saved</>;
}

export interface ContactEditorProps {
  employee: ContactEmployee;
  /** Values shown in the inputs: the saved record with any edits on top. */
  draft: ContactDraft;
  /** Phone text as typed, or the formatted saved number when untouched. */
  phoneValue: string;
  state: RowSaveState;
  canEdit: boolean;
  dirty: boolean;
  onFieldChange: (field: ContactField, value: string) => void;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
  onToggleSamePerson: (checked: boolean) => void;
  onConfirmSamePerson: () => void;
  onKeepMine: () => void;
  onUseTheirs: () => void;
  onCancel: () => void;
  onSave: () => void;
  className?: string;
}

export function ContactEditor({
  employee, draft, phoneValue, state, canEdit, dirty, onFieldChange, onKeyDown, onToggleSamePerson,
  onConfirmSamePerson, onKeepMine, onUseTheirs, onCancel, onSave, className,
}: ContactEditorProps): ReactElement {
  const name = `${employee.first_name} ${employee.last_name}`;
  const disabled = !canEdit || state.saving;
  const canSave = !disabled && (dirty || (state.samePersonRequired && state.samePersonChecked));
  const fieldProps = (field: ContactField): Pick<EditorFieldProps, 'value' | 'disabled' | 'errors' | 'onChange' | 'onKeyDown'> => ({
    value: draft[field],
    disabled,
    errors: state.fieldErrors[field] ?? [],
    onChange: (value) => onFieldChange(field, field === 'state' ? value.toUpperCase() : value),
    onKeyDown,
  });

  return (
    <div className={cn('space-y-4 bg-white', className)}>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <div>
          <EditorField label="Email" ariaLabel={`Email for ${name}`} type="email" placeholder="name@example.com"
            {...fieldProps('email')} errors={state.samePersonRequired ? [] : state.fieldErrors.email ?? []} />
          <RowInlineFeedback
            employee={employee}
            state={state}
            field="email"
            hidePrimaryFieldError
            canEdit={canEdit}
            onToggleSamePerson={onToggleSamePerson}
            onConfirmAndSave={onConfirmSamePerson}
          />
        </div>
        <EditorField label="Mobile" ariaLabel={`Mobile for ${name}`} type="tel" placeholder="(671) 555-0100" inputClassName="tabular-nums"
          hint="For a 7-digit Guam number, +1 671 is added for you." {...fieldProps('phone')}
          value={phoneValue} />
      </div>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)_72px_112px]">
        <EditorField label="Street address" ariaLabel={`Street address for ${name}`} placeholder="Street address" className="col-span-2 lg:col-span-1" {...fieldProps('address_line1')} />
        <EditorField label="Apt / Unit (optional)" ariaLabel={`Apt or unit for ${name}`} placeholder="Apt, suite, or box" className="col-span-2 lg:col-span-1" {...fieldProps('address_line2')} />
        <EditorField label="City" ariaLabel={`City for ${name}`} placeholder="Hagatna" className="col-span-2 lg:col-span-1" {...fieldProps('city')} />
        <EditorField label="State" ariaLabel={`State for ${name}`} placeholder="GU" maxLength={2} inputClassName="uppercase" {...fieldProps('state')} />
        <EditorField label="ZIP" ariaLabel={`ZIP for ${name}`} placeholder="96910" inputClassName="tabular-nums" {...fieldProps('zip')} />
      </div>

      {state.conflict && (
        <RowConflictBanner
          conflict={state.conflict}
          saving={state.saving}
          onKeep={onKeepMine}
          onDiscard={onUseTheirs}
        />
      )}
      {state.error && !state.conflict && !state.samePersonRequired && !Object.entries(state.fieldErrors).some(([field, messages]) => field !== 'base' && messages.length > 0) && (
        <Alert tone="error">
          {state.error}{state.pendingAddressRequestId && (
            <> <Link className="font-medium underline" to={`/change-requests?request_id=${state.pendingAddressRequestId}`}>View address request</Link></>
          )}
        </Alert>
      )}

      <div className="flex flex-wrap items-center justify-end gap-2">
        <p className="mr-auto hidden text-xs text-neutral-500 [@media(hover:hover)_and_(pointer:fine)]:block">Press Enter to save.</p>
        <Button variant="outline" size="sm" aria-label={`Cancel editing ${name}`} disabled={state.saving} onClick={onCancel} className="min-h-11 flex-1 sm:flex-none lg:min-h-0">
          Cancel
        </Button>
        <Button
          size="sm"
          aria-label={`Save ${name}`}
          disabled={!canSave}
          loading={state.saving}
          loadingLabel="Saving"
          onClick={onSave}
          className="min-h-11 flex-1 sm:flex-none lg:min-h-0"
        >
          <Save className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
          Save
        </Button>
      </div>
    </div>
  );
}
