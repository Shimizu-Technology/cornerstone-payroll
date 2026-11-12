import { Header } from '@/components/layout/Header';
import { PortalMessagesPanel } from '@/components/client-portal/PortalMessagesPanel';
import { clientPortalThreadsApi, clientDocumentsApi } from '@/services/api';

export function ClientMessages() {
  return <div><Header title="Messages" description="Conversations with Cornerstone Payroll." /><div className="p-4 sm:p-6 lg:p-8"><PortalMessagesPanel api={clientPortalThreadsApi} documents={[]} searchDocuments={search => clientDocumentsApi.list({ search, per_page: 25 })} audienceLabel="Cornerstone" description="Ask a question or reply to your payroll team." /></div></div>;
}
