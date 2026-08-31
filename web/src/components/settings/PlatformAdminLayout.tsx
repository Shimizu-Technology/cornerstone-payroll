import type { ReactElement } from 'react';
import { SettingsShell } from './SettingsShell';
import { platformAdminNavigation } from './settings-navigation';

export function PlatformAdminLayout(): ReactElement {
  return (
    <SettingsShell
      title="Platform Administration"
      description="System-wide controls that affect every organization using Cornerstone Payroll."
      contextLabel="Scope"
      contextValue="Entire platform"
      items={platformAdminNavigation}
    />
  );
}
