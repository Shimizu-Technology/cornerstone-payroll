import { useState } from 'react';
import { useCompany } from '@/contexts/CompanyContext';
import { Button } from '@/components/ui/button';
import { canWriteCompany, isTestWorkspaceCompany } from '@/lib/company-write-access';

export const financeWriteBlockedMessage = 'You are in a payroll test workspace. This finance book contains live records, so changes are unavailable. Select a live client to continue.';

export function FinanceWriteNotice() {
  const { activeCompany, companies = [], switchCompany } = useCompany();
  const [selected, setSelected] = useState('');
  if (!isTestWorkspaceCompany(activeCompany)) return null;
  const liveClients = companies.filter(company => company.organization_id === activeCompany?.organization_id && company.active && canWriteCompany(company) && !isTestWorkspaceCompany(company));
  const destination = liveClients.find(company => String(company.id) === selected);
  return <section aria-label="Finance changes unavailable" className="space-y-3 border-b border-amber-300 bg-amber-50 px-4 py-4 text-sm text-amber-950 sm:px-6">
    <p role="status">{financeWriteBlockedMessage}</p>
    <p>Existing finance records remain available. Changing the payroll client keeps this finance book and your unsaved draft; it does not save or send anything.</p>
    {liveClients.length > 0 ? <div className="flex flex-wrap items-end gap-3">
      <label className="block font-medium">Live payroll client<select value={selected} onChange={event => setSelected(event.target.value)} className="mt-1 block min-h-11 w-full rounded-lg border border-amber-300 bg-white px-3 text-neutral-900"><option value="">Choose a live client</option>{liveClients.map(company => <option key={company.id} value={company.id}>{company.name}</option>)}</select></label>
      <Button disabled={!destination} onClick={() => { if (destination) switchCompany(destination.id); }}>Use selected live client</Button>
    </div> : <p className="font-medium">An administrator must provide an accessible live client before you can make finance changes.</p>}
  </section>;
}
