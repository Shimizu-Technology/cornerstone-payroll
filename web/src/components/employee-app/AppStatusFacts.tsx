// The facts shared by the employee app status report and the employee
// profile's Employee app panel: account, terms, and paperless answers.
import { Badge } from '@/components/ui/badge';
import { formatEmployeeAppDate } from '@/services/employee-app-rollout-api';
import {
  answerLabels, type AnswerFact, type AppAccount, type EmployeeAgreements, type TermsAcceptance,
} from '@/services/employee-app-status-api';

export function AccountCell({ account, showLastOpened = false }: {
  account: Pick<AppAccount, 'status' | 'label' | 'invite_sent_at' | 'signed_up_at'> & Partial<AppAccount>;
  showLastOpened?: boolean;
}) {
  const tone = account.status === 'active' ? 'success'
    : account.status === 'invite_expired' || account.status === 'locked' || account.status === 'deactivated' ? 'warning' : 'default';
  let detail: string | null = null;
  if (account.status === 'active' && account.signed_up_at) detail = `Signed up ${formatEmployeeAppDate(account.signed_up_at)}`;
  else if ((account.status === 'invited' || account.status === 'invite_expired') && account.invite_sent_at) {
    detail = `Sent ${formatEmployeeAppDate(account.invite_sent_at)}`
      + (account.invite_expires_at ? ` · ${account.invite_expired ? 'expired' : 'expires'} ${formatEmployeeAppDate(account.invite_expires_at)}` : '');
  } else if (account.status === 'locked' && account.locked_until) detail = `Locked until ${formatEmployeeAppDate(account.locked_until, true)}`;
  return (
    <div className="space-y-1">
      <Badge variant={tone}>{account.label}</Badge>
      {detail && <p className="text-xs text-neutral-600">{detail}</p>}
      {showLastOpened && account.signed_up_at && (
        <p className="text-xs text-neutral-600">{account.last_opened_at ? `Last opened ${formatEmployeeAppDate(account.last_opened_at)}` : 'Hasn’t opened the app'}</p>
      )}
    </div>
  );
}

export function TermsFact({ terms }: { terms: TermsAcceptance }) {
  if (!terms.version || !terms.accepted_at) return <Badge variant="outline">Not accepted</Badge>;
  return (
    <div className="space-y-1">
      <Badge variant={terms.current ? 'success' : 'warning'}>{terms.current ? 'Accepted' : 'Older version'}</Badge>
      <p className="text-xs text-neutral-600 [overflow-wrap:anywhere]">{terms.version} · {formatEmployeeAppDate(terms.accepted_at)}</p>
    </div>
  );
}

export function AnswerCell({ fact }: { fact: AnswerFact }) {
  const tone = fact.answer === 'paperless' ? 'success' : fact.answer === 'keep_paper' ? 'info' : 'outline';
  return (
    <div className="space-y-1">
      <Badge variant={tone}>{answerLabels[fact.answer]}</Badge>
      {fact.answered_at && <p className="text-xs text-neutral-600">{formatEmployeeAppDate(fact.answered_at)}</p>}
    </div>
  );
}


/** The profile panel's list: when they last opened the app, terms, and both paperless answers. */
export function AgreementFacts({ agreements }: { agreements: EmployeeAgreements }) {
  const { account } = agreements;
  return (
    <dl aria-label="Agreements" className="grid gap-3 rounded-xl border border-neutral-200 p-3 sm:grid-cols-2">
      <Fact label="Last opened the app">
        <p className="text-sm text-neutral-900">{account.last_opened_at ? formatEmployeeAppDate(account.last_opened_at, true) : 'Never'}</p>
      </Fact>
      <Fact label="Employee App Terms and Privacy"><TermsFact terms={agreements.terms} /></Fact>
      <Fact label="Pay stubs"><AnswerCell fact={agreements.pay_statements} /></Fact>
      <Fact label="W-2GU"><AnswerCell fact={agreements.w2gu} /></Fact>
      {!agreements.delivery_consent_enabled && (
        <p className="text-xs text-neutral-600 sm:col-span-2">Employees aren’t asked about paperless yet. Paper copies continue.</p>
      )}
    </dl>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <dt className="text-xs font-semibold text-neutral-600">{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}
