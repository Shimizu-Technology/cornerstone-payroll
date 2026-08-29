import { useAuth } from '@/contexts/AuthContext';
import { SettingsShell } from './SettingsShell';
import { firmSettingsNavigation } from './settings-navigation';

export function FirmSettingsLayout() {
  const { user, can } = useAuth();
  const visibleItems = firmSettingsNavigation.filter((item) => !item.capability || can(item.capability));

  return (
    <SettingsShell
      title="Firm Settings"
      description="Shared people and resources for the payroll firm, independent of the selected client."
      contextLabel="Firm"
      contextValue={user?.organization_name || 'Payroll organization'}
      items={visibleItems}
    />
  );
}
