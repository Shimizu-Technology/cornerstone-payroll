import type { ReactElement } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { SettingsShell } from './SettingsShell';
import { clientSettingsNavigation } from './settings-navigation';

export function ClientSettingsLayout(): ReactElement {
  const { can } = useAuth();
  const { activeCompany } = useCompany();
  const visibleItems = clientSettingsNavigation.filter((item) => !item.capability || can(item.capability));

  return (
    <SettingsShell
      title="Client Settings"
      description="Configuration that belongs to the selected employer and follows its payroll history."
      contextLabel="Client"
      contextValue={activeCompany?.name}
      items={visibleItems}
    />
  );
}
