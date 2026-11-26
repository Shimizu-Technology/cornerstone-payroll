import { formatPhone } from '@/lib/display-phone';

const labels: Record<string, string> = {
  address_line1: 'Street address',
  address_line2: 'Apartment or unit',
  zip: 'ZIP code',
  email: 'Personal email',
  phone: 'Phone',
  ssn_encrypted: 'Social Security number',
  contractor_ein: 'Employer identification number',
  w4_election_received: 'Withholding form received',
  pay_statements_delivery: 'Pay statements delivery',
  w2gu_delivery: 'Form W-2GU delivery',
};

// Stored changes come back in database key order (short keys first), so ZIP
// would lead the address. Known fields read in form order; others keep theirs.
const fieldOrder = [
  'first_name', 'middle_name', 'last_name', 'suffix',
  'email', 'phone',
  'address_line1', 'line1', 'address_line2', 'line2', 'city', 'state', 'zip',
];

function orderedFields(fields: string[]) {
  const rank = (field: string) => {
    const index = fieldOrder.indexOf(field);
    return index === -1 ? fieldOrder.length : index;
  };
  return fields
    .map((field, index) => ({ field, index }))
    .sort((a, b) => rank(a.field) - rank(b.field) || a.index - b.index)
    .map(({ field }) => field);
}

function fieldLabel(field: string) {
  return labels[field] ?? field.replace(/^w4_/, 'W-4 ').replaceAll('_', ' ').replace(/^./, (value) => value.toUpperCase());
}

function displayValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (Array.isArray(value)) return value.map(displayValue).join('\n') || '—';
  if (typeof value === 'object') {
    const entries = value as Record<string, unknown>;
    return orderedFields(Object.keys(entries)).map((key) => `${fieldLabel(key)}: ${displayValue(entries[key])}`).join('\n') || '—';
  }
  return String(value);
}

export function ChangeComparison({ before = {}, after = {}, requested = false, current = false }: {
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
  requested?: boolean;
  current?: boolean;
}) {
  const fields = orderedFields(Object.keys(after));
  if (!fields.length) return null;

  return (
    <table className="w-full table-fixed border-collapse text-left text-sm">
      <thead className="border-b border-neutral-200 text-xs text-neutral-600">
        <tr>
          <th scope="col" className="w-[28%] p-2 font-medium">Field</th>
          <th scope="col" className="p-2 font-medium">{current ? 'Current' : 'Before'}</th>
          <th scope="col" className="p-2 font-medium">{requested ? 'Requested' : 'After'}</th>
        </tr>
      </thead>
      <tbody className="divide-y divide-neutral-200">
        {fields.map((field) => (
          <tr key={field} className="align-top">
            <th scope="row" className="break-words p-2 font-medium text-neutral-900">{fieldLabel(field)}</th>
            {[before[field], after[field]].map((value, index) => (
              <td key={index} className="whitespace-pre-line break-words p-2 text-neutral-700">
                {field === 'phone' && typeof value === 'string' && value ? formatPhone(value) : displayValue(value)}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
