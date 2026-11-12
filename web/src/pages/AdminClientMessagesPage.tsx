import type { ReactElement } from 'react';
import { useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { PortalMessagesPanel } from '@/components/client-portal/PortalMessagesPanel';
import { adminClientDocumentsApi, adminPortalThreadsApi } from '@/services/api';
import { useCompany } from '@/contexts/CompanyContext';

// The selected client's conversations on their own page, so a phone opens
// straight to the list instead of below the document upload form.
export function AdminClientMessagesPage(): ReactElement {
  const [searchParams] = useSearchParams();
  const { activeCompany } = useCompany();
  return (
    <div>
      <Header contextLabel="Client" contextValue={activeCompany?.name} title="Client Messages" description="Conversations and file requests with this client." />
      <div className="p-4 sm:p-6 lg:p-8">
        <PortalMessagesPanel
          initialThreadId={Number(searchParams.get('inbox') ? searchParams.get('thread_id') : null) || null}
          api={adminPortalThreadsApi}
          documentsApi={adminClientDocumentsApi}
          audience="staff"
          documents={[]}
          audienceLabel="to the client"
          description="Answer questions, request a missing file, and accept what the client sends."
          canResolve
        />
      </div>
    </div>
  );
}
