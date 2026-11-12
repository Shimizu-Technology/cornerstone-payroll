import type { ReactElement } from 'react';
import { Header } from '@/components/layout/Header';
import { PortalMessagesPanel } from '@/components/client-portal/PortalMessagesPanel';
import { clientPortalThreadsApi, clientDocumentsApi } from '@/services/api';

export function ClientMessages(): ReactElement {
  return <div><Header title="Messages" description="Conversations with Cornerstone Payroll." /><div className="p-4 sm:p-6 lg:p-8"><PortalMessagesPanel api={clientPortalThreadsApi} documents={[]} documentsApi={clientDocumentsApi} audience="client" audienceLabel="Cornerstone" description="Ask a question, reply, or send a file your payroll team asked for." /></div></div>;
}
