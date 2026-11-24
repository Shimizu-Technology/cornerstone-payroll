// My info: the employee's own contact details (M4-7, D4).
// - Mobile phone, personal email and emergency contacts apply right away,
//   after the person confirms it's them (step-up, M4-1).
// - A home address change is a request the company approves.
// - Legal name and SSN stay with Cornerstone.
// Former employees and view-only "Sign in as" see everything read-only.
import { useState, type FormEvent, type ReactElement, type ReactNode } from 'react';
import { BadgeCheck, LogOut, Pencil, Plus, ShieldCheck, Trash2, UserRound } from 'lucide-react';
import { EmployeeApiError, StepUpCancelledError } from './api';
import { askManager } from './brand';
import type { Address, AddressRequest, EmergencyContact, EmployeeProfile } from './contracts';
import { useBrand, useEmployeeAuth, useReadySession } from './contexts';
import { addressLines, formatPhone, longDate } from './format';
import { useSignOut } from './hooks';
import { Card, Chip, EmpButton, Field, FormMessage, LoadProblem, Page, Placeholder, SkeletonRows } from './ui';
import { useEmployeeData } from './useEmployeeData';

const PHONE_DIGITS = /^\+?[\d\s().-]+$/;
const EMAIL = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;
const ZIP = /^\d{5}(?:-\d{4})?$/;

function phoneProblem(phone: string): string | null {
  const digits = phone.replace(/\D/g, '');
  if (!phone.trim()) return 'Enter a phone number.';
  return PHONE_DIGITS.test(phone.trim()) && digits.length >= 7 && digits.length <= 15 ? null : 'Enter a phone number with 7 to 15 digits.';
}

function emailProblem(email: string): string | null {
  if (!email.trim()) return 'Enter an email address.';
  return EMAIL.test(email.trim()) ? null : 'Enter an email address like name@example.com.';
}

/** What a failed change says. It never says whether anyone else's record exists. */
function changeMessage(error: unknown, what: string): string {
  if (error instanceof StepUpCancelledError) return `Not saved. To save your ${what}, confirm it's you.`;
  if (error instanceof EmployeeApiError) {
    switch (error.kind) {
      case 'invalid': return `Check your ${what} and try again.`;
      case 'conflict': return 'A change is already being reviewed. Try again after it is decided.';
      case 'offline': return "You're offline. Connect to Wi-Fi or data, then try again.";
      case 'rate_limited': return 'Too many tries. Wait a minute, then try again.';
      default: break;
    }
  }
  return `Couldn't save your ${what}. Try again in a minute.`;
}

/**
 * Runs one change: step-up first if the API asks for it, then the change.
 * Returns the new profile, or null after showing why it didn't save.
 */
function useChange(): { run: (what: string, attempt: () => Promise<EmployeeProfile>) => Promise<EmployeeProfile | null>; saving: boolean; error: string | null; clearError: () => void } {
  const { stepUp } = useEmployeeAuth();
  const { reportError } = useReadySession();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run = async (what: string, attempt: () => Promise<EmployeeProfile>): Promise<EmployeeProfile | null> => {
    setSaving(true);
    setError(null);
    try {
      return await stepUp(attempt);
    } catch (failure) {
      // An ended link or session goes to the session screens, as everywhere else.
      if (failure instanceof EmployeeApiError && (failure.kind === 'not_found' || failure.kind === 'unauthorized')) reportError(failure);
      else setError(changeMessage(failure, what));
      return null;
    } finally {
      setSaving(false);
    }
  };
  return { run, saving, error, clearError: () => setError(null) };
}

function StepUpNote(): ReactElement {
  return (
    <p className="emp-hint emp-inline-icon">
      <ShieldCheck aria-hidden="true" className="size-5 shrink-0" />
      To keep your account safe, we'll ask you to confirm it's you before saving.
    </p>
  );
}

function FormButtons({ saving, label, onCancel, extra }: { saving: boolean; label: string; onCancel: () => void; extra?: ReactNode }): ReactElement {
  return (
    <div className="emp-form-buttons">
      <EmpButton type="submit" disabled={saving} aria-busy={saving}>{saving ? 'Saving…' : label}</EmpButton>
      {extra}
      <EmpButton variant="quiet" onClick={onCancel} disabled={saving}>Cancel</EmpButton>
    </div>
  );
}

interface ProfileProps {
  profile: EmployeeProfile;
  onSaved: (profile: EmployeeProfile, message: string) => void;
  editable: boolean;
  /** The confirmation for the last change made in this card, shown where the person is looking. */
  notice: string | null;
}

function SavedNotice({ notice }: { notice: string | null }): ReactElement | null {
  return notice ? <FormMessage tone="good">{notice}</FormMessage> : null;
}

// ---------- Phone and email ----------

function DetailRow({ label, value, badge, action }: { label: string; value: string | null; badge?: ReactNode; action?: ReactNode }): ReactElement {
  return (
    <div className="emp-detail">
      <div className="min-w-0 flex-1">
        <p className="emp-label-quiet">{label}</p>
        <p className="emp-detail-value">{value ?? <span className="text-neutral-500">Not added yet</span>}</p>
        {badge}
      </div>
      {action}
    </div>
  );
}

function ChangeButton({ onClick, label }: { onClick: () => void; label: string }): ReactElement {
  return (
    <EmpButton variant="secondary" className="emp-btn-small" onClick={onClick} aria-label={label}>
      <Pencil aria-hidden="true" className="size-4" />Change
    </EmpButton>
  );
}

function PhoneEditor({ profile, onSaved, onClose }: { profile: EmployeeProfile; onSaved: ProfileProps['onSaved']; onClose: () => void }): ReactElement {
  const { api, state } = useReadySession();
  const [phone, setPhone] = useState(profile.phone ?? '');
  const [problem, setProblem] = useState<string | null>(null);
  const change = useChange();
  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const invalid = phoneProblem(phone);
    setProblem(invalid);
    if (invalid) return;
    const saved = await change.run('phone number', () => api.updatePhone(state.link.id, phone.trim()));
    if (saved) {
      onSaved(saved, 'Phone number saved.');
      onClose();
    }
  };
  return (
    <form className="emp-form" onSubmit={(event) => { void submit(event); }} noValidate>
      <Field label="Mobile phone" type="tel" inputMode="tel" autoComplete="tel" value={phone} onChange={(e) => setPhone(e.target.value)} error={problem} autoFocus />
      <StepUpNote />
      {change.error && <FormMessage tone="bad">{change.error}</FormMessage>}
      <FormButtons saving={change.saving} label="Save phone" onCancel={onClose} />
    </form>
  );
}

function EmailEditor({ profile, onSaved, onClose }: { profile: EmployeeProfile; onSaved: ProfileProps['onSaved']; onClose: () => void }): ReactElement {
  const { api, state } = useReadySession();
  const { stepUp } = useEmployeeAuth();
  const [email, setEmail] = useState(profile.email ?? '');
  const [code, setCode] = useState('');
  const [verificationId, setVerificationId] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const change = useChange();
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);

  const send = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const invalid = emailProblem(email);
    setProblem(invalid);
    if (invalid) return;
    setSending(true);
    setSendError(null);
    try {
      setVerificationId(await stepUp(() => api.startEmailChange(state.link.id, email.trim())));
    } catch (failure) {
      setSendError(changeMessage(failure, 'email'));
    } finally {
      setSending(false);
    }
  };

  const confirm = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!verificationId) return;
    if (!/^\d{4,8}$/.test(code.trim())) {
      setProblem('Enter the code from the email.');
      return;
    }
    setProblem(null);
    const saved = await change.run('email', () => api.confirmEmailChange(state.link.id, verificationId, code.trim()));
    if (saved) {
      onSaved(saved, 'Email verified and saved.');
      onClose();
    }
  };

  if (verificationId) {
    return (
      <form className="emp-form" onSubmit={(event) => { void confirm(event); }} noValidate>
        <p className="text-neutral-800">We sent a code to <strong className="break-all">{email.trim()}</strong>. Enter it here to finish.</p>
        <Field label="Code from the email" inputMode="numeric" autoComplete="one-time-code" value={code} onChange={(e) => setCode(e.target.value)} error={problem} autoFocus />
        {change.error && <FormMessage tone="bad">{change.error}</FormMessage>}
        <FormButtons saving={change.saving} label="Confirm email" onCancel={onClose} />
      </form>
    );
  }
  return (
    <form className="emp-form" onSubmit={(event) => { void send(event); }} noValidate>
      <Field
        label="Personal email"
        hint="Pay stub notices go here. Use your own email, not a shared one."
        type="email"
        inputMode="email"
        autoComplete="email"
        autoCapitalize="none"
        spellCheck={false}
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        error={problem}
        autoFocus
      />
      <StepUpNote />
      {sendError && <FormMessage tone="bad">{sendError}</FormMessage>}
      <FormButtons saving={sending} label="Send code" onCancel={onClose} />
    </form>
  );
}

function ContactCard({ profile, onSaved, editable, notice }: ProfileProps): ReactElement {
  const [editing, setEditing] = useState<'phone' | 'email' | null>(null);
  return (
    <Card title="Contact details">
      {!editing && <div className="mb-4 empty:hidden"><SavedNotice notice={notice} /></div>}
      <div className="emp-details-list">
        {editing === 'phone' ? <PhoneEditor profile={profile} onSaved={onSaved} onClose={() => setEditing(null)} /> : (
          <DetailRow
            label="Mobile phone"
            value={profile.phone ? formatPhone(profile.phone) : null}
            badge={profile.phone && profile.phoneConfirmed ? <Chip tone="good" icon={BadgeCheck}>Confirmed by you</Chip> : undefined}
            action={editable && !editing ? <ChangeButton label="Change mobile phone" onClick={() => setEditing('phone')} /> : undefined}
          />
        )}
        {editing === 'email' ? <EmailEditor profile={profile} onSaved={onSaved} onClose={() => setEditing(null)} /> : (
          <DetailRow
            label="Personal email"
            value={profile.email}
            badge={profile.email && profile.emailVerified ? <Chip tone="good" icon={BadgeCheck}>Verified</Chip> : undefined}
            action={editable && !editing ? <ChangeButton label="Change personal email" onClick={() => setEditing('email')} /> : undefined}
          />
        )}
      </div>
    </Card>
  );
}

// ---------- Home address ----------

const EMPTY_ADDRESS: Address = { line1: '', line2: '', city: '', state: 'GU', zip: '' };

function AddressBlock({ address }: { address: Address | null }): ReactElement {
  if (!address) return <p className="text-neutral-500">Not added yet</p>;
  return <address className="not-italic">{addressLines(address).map((line) => <span key={line} className="block">{line}</span>)}</address>;
}

function AddressForm({ initial, requestId, onSaved, onClose }: { initial: Address; requestId?: string; onSaved: ProfileProps['onSaved']; onClose: () => void }): ReactElement {
  const { api, state } = useReadySession();
  const brand = useBrand();
  const [address, setAddress] = useState(initial);
  const [problems, setProblems] = useState<Partial<Record<keyof Address, string>>>({});
  const change = useChange();
  const set = (field: keyof Address) => (event: { target: { value: string } }): void => setAddress((a) => ({ ...a, [field]: event.target.value }));
  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    const next: Partial<Record<keyof Address, string>> = {};
    if (!address.line1.trim()) next.line1 = 'Enter the street address.';
    if (!address.city.trim()) next.city = 'Enter the village or city.';
    if (!address.state.trim()) next.state = 'Enter the state or territory.';
    if (!ZIP.test(address.zip.trim())) next.zip = 'Enter a 5-digit ZIP code.';
    setProblems(next);
    if (Object.keys(next).length > 0) return;
    const saved = await change.run('address', () => api.requestAddressChange(state.link.id, address, requestId));
    if (saved) {
      onSaved(saved, requestId ? 'Request updated.' : `Request sent to ${brand.isFallback ? 'your employer' : brand.name}.`);
      onClose();
    }
  };
  return (
    <form className="emp-form" onSubmit={(event) => { void submit(event); }} noValidate aria-label="New home address">
      <Field label="Street address" autoComplete="address-line1" value={address.line1} onChange={set('line1')} error={problems.line1} autoFocus />
      <Field label="Apartment, unit or PO box (optional)" autoComplete="address-line2" value={address.line2} onChange={set('line2')} />
      <div className="emp-field-row">
        <Field label="Village or city" autoComplete="address-level2" value={address.city} onChange={set('city')} error={problems.city} className="flex-[2]" />
        <Field label="State" autoComplete="address-level1" value={address.state} onChange={set('state')} error={problems.state} className="flex-1" maxLength={2} autoCapitalize="characters" />
      </div>
      <Field label="ZIP code" autoComplete="postal-code" inputMode="numeric" value={address.zip} onChange={set('zip')} error={problems.zip} className="emp-field-short" />
      <p className="emp-hint">{brand.isFallback ? 'Your employer' : brand.name} checks the new address before it's used.</p>
      <StepUpNote />
      {change.error && <FormMessage tone="bad">{change.error}</FormMessage>}
      <FormButtons saving={change.saving} label={requestId ? 'Save request' : 'Send request'} onCancel={onClose} />
    </form>
  );
}

function RequestStatus({ request }: { request: AddressRequest }): ReactElement {
  if (request.status === 'pending') return <Chip tone="warn">Waiting for approval</Chip>;
  if (request.status === 'approved') return <Chip tone="good">Approved</Chip>;
  return <Chip tone="bad">Not approved</Chip>;
}

function AddressCard({ profile, onSaved, editable, notice }: ProfileProps): ReactElement {
  const { api, state } = useReadySession();
  const brand = useBrand();
  const [mode, setMode] = useState<'view' | 'new' | 'edit'>('view');
  const cancel = useChange();
  const request = profile.addressRequest;
  const pending = request?.status === 'pending' ? request : null;
  const company = brand.isFallback ? 'your employer' : brand.name;

  const cancelRequest = async (): Promise<void> => {
    if (!pending) return;
    const saved = await cancel.run('request', () => api.cancelAddressRequest(state.link.id, pending.id));
    if (saved) onSaved(saved, 'Request cancelled.');
  };

  return (
    <Card title="Home address">
      <div className="space-y-4">
        <p className="emp-hint">Used for paychecks, W-2s and other tax and work documents.</p>
        {mode === 'view' && <SavedNotice notice={notice} />}
        {mode === 'new' && <AddressForm initial={profile.address ? { ...profile.address } : EMPTY_ADDRESS} onSaved={onSaved} onClose={() => setMode('view')} />}
        {mode === 'edit' && pending && <AddressForm initial={pending.requested} requestId={pending.id} onSaved={onSaved} onClose={() => setMode('view')} />}
        {mode === 'view' && (
          pending ? (
            <div className="space-y-4">
              <div className="emp-compare-grid">
                <div>
                  <p className="emp-label-quiet">Current</p>
                  <AddressBlock address={profile.address} />
                </div>
                <div>
                  <p className="emp-label-quiet">Requested</p>
                  <AddressBlock address={pending.requested} />
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <RequestStatus request={pending} />
                {pending.submittedAt && <span className="emp-hint">Sent {longDate(pending.submittedAt)}</span>}
              </div>
              <p className="text-neutral-700">{company} will review it. You'll see the decision here.</p>
              {editable && (
                <div className="emp-form-buttons">
                  <EmpButton variant="secondary" onClick={() => setMode('edit')}>Edit request</EmpButton>
                  <EmpButton variant="quiet" onClick={() => { void cancelRequest(); }} disabled={cancel.saving}>{cancel.saving ? 'Cancelling…' : 'Cancel request'}</EmpButton>
                </div>
              )}
              {cancel.error && <FormMessage tone="bad">{cancel.error}</FormMessage>}
            </div>
          ) : (
            <div className="space-y-4">
              <AddressBlock address={profile.address} />
              {request?.status === 'approved' && request.decidedAt && (
                <FormMessage tone="good">Your new address was approved on {longDate(request.decidedAt)}. Your W-2 will be mailed here.</FormMessage>
              )}
              {request?.status === 'rejected' && (
                <div className="space-y-1">
                  <div className="flex flex-wrap items-center gap-2"><RequestStatus request={request} />{request.decidedAt && <span className="emp-hint">{longDate(request.decidedAt)}</span>}</div>
                  <p className="text-neutral-700">{request.decisionNote ?? `Your request to change it to ${addressLines(request.requested).join(', ')} wasn't approved. ${askManager(brand, 'Questions? Ask your manager')}`}</p>
                </div>
              )}
              {editable && (profile.otherRequestPending
                ? <p className="text-neutral-700">A change is already being reviewed. You can request a new address after it's decided.</p>
                : <EmpButton variant="secondary" className="emp-narrow-button" block onClick={() => setMode('new')}>Request a change</EmpButton>)}
            </div>
          )
        )}
      </div>
    </Card>
  );
}

// ---------- Emergency contacts ----------

function EmergencyForm({ contact, onSaved, onClose }: { contact?: EmergencyContact; onSaved: ProfileProps['onSaved']; onClose: () => void }): ReactElement {
  const { api, state } = useReadySession();
  const [draft, setDraft] = useState({ name: contact?.name ?? '', relationship: contact?.relationship ?? '', phone: contact?.phone ?? '' });
  const [problems, setProblems] = useState<{ name?: string; phone?: string }>({});
  const [formKey, setFormKey] = useState(0);
  const change = useChange();
  const submit = async (event: { preventDefault: () => void }, another: boolean): Promise<void> => {
    event.preventDefault();
    const next = { name: draft.name.trim() ? undefined : 'Enter their name.', phone: phoneProblem(draft.phone) ?? undefined };
    setProblems(next);
    if (next.name || next.phone) return;
    const saved = await change.run('emergency contact', () => api.saveEmergencyContact(state.link.id, { id: contact?.id, ...draft }));
    if (!saved) return;
    onSaved(saved, another ? `${draft.name.trim()} saved. Add another contact.` : `${draft.name.trim()} saved.`);
    if (another) {
      setDraft({ name: '', relationship: '', phone: '' });
      setFormKey((n) => n + 1);
    } else {
      onClose();
    }
  };
  const prefix = contact ? `emp-ec-${contact.id}` : `emp-ec-new-${formKey}`;
  return (
    <form key={formKey} className="emp-form" onSubmit={(event) => { void submit(event, false); }} noValidate aria-label={contact ? `Edit ${contact.name}` : 'New emergency contact'}>
      <Field id={`${prefix}-name`} label="Name" autoComplete="off" value={draft.name} onChange={(e) => setDraft((d) => ({ ...d, name: e.target.value }))} error={problems.name} autoFocus />
      <Field id={`${prefix}-relationship`} label="Relationship (optional)" hint="For example: mother, partner, friend" autoComplete="off" value={draft.relationship} onChange={(e) => setDraft((d) => ({ ...d, relationship: e.target.value }))} />
      <Field id={`${prefix}-phone`} label="Phone" type="tel" inputMode="tel" autoComplete="off" value={draft.phone} onChange={(e) => setDraft((d) => ({ ...d, phone: e.target.value }))} error={problems.phone} />
      <StepUpNote />
      {change.error && <FormMessage tone="bad">{change.error}</FormMessage>}
      <FormButtons
        saving={change.saving}
        label="Save"
        onCancel={onClose}
        extra={contact ? undefined : (
          <EmpButton variant="secondary" disabled={change.saving} onClick={(event) => { void submit(event, true); }}>Save &amp; add another</EmpButton>
        )}
      />
    </form>
  );
}

function EmergencyCard({ profile, onSaved, editable, notice }: ProfileProps): ReactElement {
  const { api, state } = useReadySession();
  const [editing, setEditing] = useState<string | 'new' | null>(null);
  const remove = useChange();
  const removeContact = async (contact: EmergencyContact): Promise<void> => {
    const saved = await remove.run('emergency contact', () => api.removeEmergencyContact(state.link.id, contact.id));
    if (saved) onSaved(saved, `${contact.name} removed.`);
  };
  return (
    <Card title="Emergency contacts">
      <div className="space-y-4">
        <SavedNotice notice={notice} />
        {profile.emergencyContacts.length === 0 && editing !== 'new' && <p className="text-neutral-600">No emergency contacts yet. Add someone we can call if something happens at work.</p>}
        {profile.emergencyContacts.length > 0 && (
          <ul className="emp-details-list" aria-label="Emergency contacts">
            {profile.emergencyContacts.map((contact) => (
              <li key={contact.id}>
                {editing === contact.id ? <EmergencyForm contact={contact} onSaved={onSaved} onClose={() => setEditing(null)} /> : (
                  <div className="emp-detail">
                    <div className="min-w-0 flex-1">
                      <p className="emp-detail-value break-words">{contact.name}</p>
                      <p className="emp-row-sub">{[contact.relationship, contact.phone && formatPhone(contact.phone)].filter(Boolean).join(' · ')}</p>
                    </div>
                    {editable && !editing && (
                      <div className="flex gap-1">
                        <EmpButton variant="quiet" className="emp-icon-button" aria-label={`Edit ${contact.name}`} onClick={() => setEditing(contact.id)}><Pencil aria-hidden="true" className="size-5" /></EmpButton>
                        <EmpButton variant="quiet" className="emp-icon-button" aria-label={`Remove ${contact.name}`} onClick={() => { void removeContact(contact); }} disabled={remove.saving}><Trash2 aria-hidden="true" className="size-5" /></EmpButton>
                      </div>
                    )}
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
        {remove.error && <FormMessage tone="bad">{remove.error}</FormMessage>}
        {editing === 'new' && <EmergencyForm onSaved={onSaved} onClose={() => setEditing(null)} />}
        {editable && !editing && (
          <EmpButton variant="secondary" className="emp-narrow-button" block onClick={() => setEditing('new')}>
            <Plus aria-hidden="true" className="size-5" />Add a contact
          </EmpButton>
        )}
      </div>
    </Card>
  );
}

// ---------- Read-only details ----------

function LegalCard({ profile }: { profile: EmployeeProfile }): ReactElement {
  return (
    <Card title="Name and Social Security number">
      <div className="space-y-4">
        <DetailRow label="Legal name" value={profile.legalName} />
        <div className="emp-notice-inline" role="note">
          <p className="font-bold">To change these, contact Cornerstone</p>
          <p className="text-neutral-700">Cornerstone runs payroll and keeps these on your tax records. Bring:</p>
          <ul className="emp-bullets">
            <li>Your Social Security card showing the new name or number</li>
            <li>For a name change, the paper that changed it, such as a marriage certificate or court order</li>
            <li>A photo ID</li>
          </ul>
        </div>
      </div>
    </Card>
  );
}

function PaymentCard({ profile }: { profile: EmployeeProfile }): ReactElement | null {
  const brand = useBrand();
  if (!profile.paymentMethod) return null;
  return (
    <Card title="How you're paid">
      <DetailRow label="Payment method" value={profile.paymentMethod === 'direct_deposit' ? 'Direct deposit' : 'Paper check'} />
      <p className="emp-hint mt-2">{brand.isFallback ? 'To change it, ask your employer.' : `To change it, ask ${brand.name}.`}</p>
    </Card>
  );
}

function AccountCard(): ReactElement {
  const signOut = useSignOut();
  const { state, chooseLink } = useReadySession();
  return (
    <div className="emp-form-buttons">
      {state.links.length > 1 && <EmpButton variant="secondary" onClick={() => chooseLink(null)}>Switch employer</EmpButton>}
      <EmpButton variant="secondary" className="emp-narrow-button" onClick={() => { void signOut(); }}>
        <LogOut aria-hidden="true" className="size-6" />
        Sign out
      </EmpButton>
    </div>
  );
}

function ProfileCards(): ReactElement {
  const { readOnly } = useReadySession();
  const brand = useBrand();
  const { state, reload, update } = useEmployeeData<EmployeeProfile>('profile', (api, linkId, signal) => api.profile(linkId, signal));
  const [saved, setSaved] = useState<{ card: 'contact' | 'address' | 'emergency'; message: string } | null>(null);
  if (state.status === 'loading') return <Card><SkeletonRows rows={4} label="Loading your details" /></Card>;
  if (state.status === 'error') return <Card><LoadProblem kind={state.kind} onRetry={reload} what="your details" /></Card>;
  const editable = readOnly === null;
  const props = (card: 'contact' | 'address' | 'emergency'): ProfileProps => ({
    profile: state.data,
    editable,
    notice: saved?.card === card ? saved.message : null,
    onSaved: (profile, message) => {
      update(profile);
      setSaved({ card, message });
    },
  });
  return (
    <>
      {readOnly === 'former' && (
        <div className="emp-notice-inline emp-span-all" role="note">
          <p className="text-neutral-700">Your details can't be changed here after your job ends. If you move, tell {brand.isFallback ? 'your employer' : brand.name} so your W-2 reaches you.</p>
        </div>
      )}
      {readOnly === 'view_only' && (
        <div className="emp-notice-inline emp-span-all" role="note"><p className="text-neutral-700">View only. Changes are turned off.</p></div>
      )}
      <ContactCard {...props('contact')} />
      <AddressCard {...props('address')} />
      <EmergencyCard {...props('emergency')} />
      <LegalCard profile={state.data} />
      <PaymentCard profile={state.data} />
    </>
  );
}

export function MyInfoTab(): ReactElement {
  const { state } = useReadySession();
  return (
    <Page title="My info">
      <div className="emp-cards-grid">
        {state.info.features.profileRequests ? <ProfileCards /> : (
          <Card>
            <Placeholder icon={UserRound} title="Your contact details will show here">
              <p>Your phone number, email and home address will be listed here.</p>
            </Placeholder>
          </Card>
        )}
      </div>
      <AccountCard />
    </Page>
  );
}
