import { useId, useState, type FormEvent } from 'react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { usersApi, type ClerkRecoveryAccount } from '@/services/api';
import type { User } from '@/types';

interface RecoverClerkLoginDialogProps {
  user: User;
  onClose: () => void;
  onBound: (user: User) => void;
}

export function RecoverClerkLoginDialog({ user, onClose, onBound }: RecoverClerkLoginDialogProps) {
  const fieldId = useId();
  const [clerkId, setClerkId] = useState('');
  const [account, setAccount] = useState<ClerkRecoveryAccount | null>(null);
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || (account ? !email : !clerkId.trim())) return;

    setBusy(true);
    setError(null);
    try {
      if (account) {
        const { data } = await usersApi.bindClerkId(user.id, { clerk_id: account.id, confirm_email: email });
        onBound(data);
      } else {
        const { data } = await usersApi.lookupClerkId(user.id, clerkId.trim());
        setAccount(data);
      }
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The Clerk request failed. Try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog open onOpenChange={open => { if (!open && !busy) onClose(); }}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Recover login for {user.name}</DialogTitle>
          <DialogDescription className="break-words">
            Link an existing Clerk account to {user.email}. Verify the recipient’s identity before binding.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="mt-4 space-y-4">
          <div>
            <label className="text-sm font-medium" htmlFor={fieldId}>Clerk user ID</label>
            <Input
              id={fieldId}
              className="mt-1 text-base sm:text-sm"
              value={clerkId}
              autoCapitalize="none"
              spellCheck={false}
              disabled={busy}
              onChange={event => {
                setClerkId(event.target.value);
                setAccount(null);
                setEmail('');
                setError(null);
              }}
            />
          </div>
          {account && (
            <div className="space-y-2 rounded-lg border border-neutral-200 p-3">
              <p className="break-words text-sm font-semibold">{account.name || 'Clerk account has no display name'}</p>
              {account.verified_emails.length === 0 ? (
                <ActionFeedback tone="error" message="This Clerk account has no verified email addresses. Verify an address in Clerk or look up a different account." />
              ) : (
                <fieldset className="min-w-0 space-y-1" disabled={busy}>
                  <legend className="text-sm font-medium">Confirm a verified email</legend>
                  {account.verified_emails.map(address => (
                    <label key={address} className="flex min-h-11 items-center gap-2 break-all text-sm">
                      <input type="radio" name="confirmed-email" className="shrink-0" checked={address === email}
                        onChange={() => setEmail(address)} />
                      {address}
                    </label>
                  ))}
                </fieldset>
              )}
            </div>
          )}
          {error && <ActionFeedback tone="error" message={error} />}
          <DialogFooter className="gap-2 sm:space-x-0">
            <Button type="button" variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
            <Button type="submit" disabled={busy || (account ? !email : !clerkId.trim())}>
              {account ? (busy ? 'Binding…' : 'Bind account') : (busy ? 'Looking up…' : 'Look up account')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
