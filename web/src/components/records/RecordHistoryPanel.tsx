import { useState } from 'react';
import { RecordActivityTimeline } from './RecordActivityTimeline';

export function RecordHistoryPanel({ companyId, recordId, recordType }: {
  companyId: number; recordId: number; recordType: 'companies' | 'employees' | 'pay_periods';
}) {
  const [opened, setOpened] = useState(false);
  return <details className="mt-2 min-w-0" onToggle={(event) => setOpened(event.currentTarget.open)}>
    <summary className="cursor-pointer py-2 text-sm font-medium text-primary-700">History</summary>
    {opened && <RecordActivityTimeline companyId={companyId} recordId={recordId} recordType={recordType} />}
  </details>;
}
