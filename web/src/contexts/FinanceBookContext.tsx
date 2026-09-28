/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { financeBooksApi, setActiveFinanceBookId, type FinanceBook } from '@/services/api';
import { Button } from '@/components/ui/button';

type FinanceBookContextValue = {
  books: FinanceBook[];
  activeBook: FinanceBook;
  switchBook: (bookId: number) => void;
  createBook: (data: { name: string; legal_name: string; kind: FinanceBook['kind']; company_id?: number }) => Promise<void>;
};

const FinanceBookContext = createContext<FinanceBookContextValue | null>(null);

function storageKey(userId: number, organizationId: number) {
  return `finance-book:v1:${userId}:${organizationId}`;
}

function storedBookId(key: string): number | null {
  try {
    const value = Number(window.localStorage.getItem(key));
    return Number.isSafeInteger(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

function rememberBookId(key: string, bookId: number) {
  try { window.localStorage.setItem(key, String(bookId)); } catch { /* Storage may be unavailable. */ }
}

/** Mount finance pages only after a fresh book list validates their write scope. */
export function FinanceBookGate({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const { activeOrganizationId, loading: companyLoading } = useCompany();
  const organizationId = activeOrganizationId ?? user?.organization_id ?? null;
  const userId = user?.id ?? null;
  const [scope, setScope] = useState<{ organizationId: number; books: FinanceBook[]; activeId: number } | null>(null);
  const scopeRef = useRef<typeof scope>(null);
  const [error, setError] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    if (!organizationId || !userId) {
      setActiveFinanceBookId(null);
      return;
    }
    let current = true;
    setActiveFinanceBookId(null);
    setScope(null);
    setError(null);
    void financeBooksApi.list().then(({ finance_books: books, effective_finance_book_id: effectiveId }) => {
      if (!current) return;
      const available = books.filter((book) => book.organization_id === organizationId);
      const key = storageKey(userId, organizationId);
      const preferredId = storedBookId(key);
      const activeBook = available.find((book) => book.id === preferredId)
        ?? available.find((book) => book.id === effectiveId)
        ?? available.find((book) => book.is_default)
        ?? available[0];
      if (!activeBook) {
        setError('No finance book is available in this organization.');
        return;
      }
      setActiveFinanceBookId(activeBook.id);
      rememberBookId(key, activeBook.id);
      setScope({ organizationId, books: available, activeId: activeBook.id });
    }).catch((loadError) => {
      if (current) setError(loadError instanceof Error ? loadError.message : 'Unable to load finance books');
    });
    return () => {
      current = false;
      setActiveFinanceBookId(null);
    };
  }, [organizationId, userId, retry]);

  const activeScope = scope?.organizationId === organizationId ? scope : null;
  scopeRef.current = activeScope;
  const activeBook = activeScope?.books.find((book) => book.id === activeScope.activeId);
  const switchBook = useCallback((bookId: number) => {
    if (!activeScope || !userId || !activeScope.books.some((book) => book.id === bookId)) return;
    setActiveFinanceBookId(bookId);
    rememberBookId(storageKey(userId, activeScope.organizationId), bookId);
    setScope({ ...activeScope, activeId: bookId });
  }, [activeScope, userId]);
  const createBook = useCallback(async (data: { name: string; legal_name: string; kind: FinanceBook['kind']; company_id?: number }) => {
    if (!activeScope || !userId) throw new Error('Choose an organization first');
    const { finance_book: book } = await financeBooksApi.create(data);
    if (book.organization_id !== activeScope.organizationId || scopeRef.current?.organizationId !== activeScope.organizationId) {
      throw new Error('The organization changed while this book was being created. Refresh the book list before continuing.');
    }
    setActiveFinanceBookId(book.id);
    rememberBookId(storageKey(userId, activeScope.organizationId), book.id);
    setScope((current) => current?.organizationId === activeScope.organizationId
      ? { ...current, books: [...current.books, book], activeId: book.id }
      : current);
  }, [activeScope, userId]);
  const value = useMemo(() => activeScope && activeBook
    ? { books: activeScope.books, activeBook, switchBook, createBook }
    : null, [activeScope, activeBook, switchBook, createBook]);

  if (!organizationId && !companyLoading) return <p role="alert" className="p-6 text-sm text-rose-700">Choose an organization before opening finance.</p>;
  if (error) return <div role="alert" className="space-y-3 p-6 text-sm text-rose-700"><p>{error}</p><Button variant="outline" onClick={() => setRetry((value) => value + 1)}>Retry</Button></div>;
  if (!value) return <p role="status" className="p-6 text-sm text-neutral-600">Loading finance books…</p>;

  return <FinanceBookContext.Provider value={value}><div key={activeBook?.id}>{children}</div></FinanceBookContext.Provider>;
}

export function useFinanceBook() {
  const context = useContext(FinanceBookContext);
  if (!context) throw new Error('Finance book context is required');
  return context;
}

export function FinanceBookSelector({ disabled = false }: { disabled?: boolean }) {
  const { user } = useAuth();
  const { companies } = useCompany();
  const { books, activeBook, switchBook, createBook } = useFinanceBook();
  const [showSetup, setShowSetup] = useState(false);
  const [name, setName] = useState('');
  const [legalName, setLegalName] = useState('');
  const [kind, setKind] = useState<FinanceBook['kind']>('client');
  const [companyId, setCompanyId] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const canManage = ['super_admin', 'org_admin', 'admin'].includes(user?.role || '');
  const eligibleCompanies = companies.filter((company) => company.organization_id === activeBook.organization_id
    && !company.test_workspace && !books.some((book) => book.company_id === company.id));
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    if (!name.trim() || !legalName.trim()) { setError('Enter a book name and legal name.'); return; }
    if (kind === 'client' && !companyId) { setError('Choose a client company.'); return; }
    setSaving(true);
    try {
      await createBook({ name: name.trim(), legal_name: legalName.trim(), kind,
        ...(kind === 'client' ? { company_id: Number(companyId) } : {}) });
      setShowSetup(false);
    } catch (createError) {
      setError(createError instanceof Error ? createError.message : 'Unable to create the finance book');
    } finally {
      setSaving(false);
    }
  };
  return (
    <div className="space-y-3">
    <section className="flex flex-col gap-2 rounded-2xl border border-primary-100 bg-primary-50/60 p-4 sm:flex-row sm:items-center sm:justify-between" aria-label="Financial book">
      <div className="min-w-0">
        <p className="text-xs font-semibold uppercase tracking-wide text-primary-700">Financial book</p>
        <p className="truncate text-sm font-semibold text-neutral-950">{activeBook.name}</p>
        <p className="text-xs text-neutral-600">Invoices, expenses, and payments in this book stay together.</p>
      </div>
      <div className="flex w-full flex-col gap-2 sm:w-72">
      {books.length > 1 && <label className="text-xs font-semibold text-neutral-700">
        Switch book
        <select
          aria-label="Switch financial book"
          value={activeBook.id}
          onChange={(event) => switchBook(Number(event.target.value))}
          disabled={disabled || saving}
          className="mt-1 min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3 text-sm font-medium text-neutral-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600 disabled:opacity-60"
        >
          {books.map((book) => <option key={book.id} value={book.id}>{book.name}{book.kind === 'organization' ? ' · Organization' : ' · Client'}</option>)}
        </select>
      </label>}
      {canManage && <button type="button" onClick={() => { setShowSetup((value) => !value); setError(null); }} disabled={disabled || saving}
        className="self-start text-xs font-semibold text-primary-800 underline-offset-2 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600 disabled:opacity-60">
        {showSetup ? 'Cancel setup' : 'Add financial book'}
      </button>}
      </div>
    </section>
    {showSetup && canManage && <form onSubmit={(event) => void submit(event)} className="space-y-4 rounded-2xl border border-neutral-200 bg-white p-4" aria-label="Add financial book">
      <div><h2 className="font-semibold text-neutral-950">Add financial book</h2><p className="text-sm text-neutral-600">Choose whose invoices and expenses this book will hold.</p></div>
      {error && <p role="alert" className="text-sm text-rose-700">{error}</p>}
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-medium">Book type<select value={kind} onChange={(event) => { setKind(event.target.value as FinanceBook['kind']); setCompanyId(''); }} disabled={saving}
          className="mt-1 min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3"><option value="client">Client company</option><option value="organization">Organization</option></select></label>
        {kind === 'client' && <label className="text-sm font-medium">Client company<select required value={companyId} onChange={(event) => {
          setCompanyId(event.target.value);
          const company = eligibleCompanies.find((candidate) => candidate.id === Number(event.target.value));
          if (company) {
            setName((current) => current || company.name);
            setLegalName((current) => current || company.name);
          }
        }} disabled={saving}
          className="mt-1 min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3"><option value="">Choose company</option>{eligibleCompanies.map((company) => <option key={company.id} value={company.id}>{company.name}</option>)}</select></label>}
        <label className="text-sm font-medium">Book name<input required value={name} onChange={(event) => setName(event.target.value)} disabled={saving} placeholder="Client bookkeeping"
          className="mt-1 min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3" /></label>
        <label className="text-sm font-medium">Legal name<input required value={legalName} onChange={(event) => setLegalName(event.target.value)} disabled={saving} placeholder="Legal entity name"
          className="mt-1 min-h-11 w-full rounded-lg border border-neutral-300 bg-white px-3" /></label>
      </div>
      {kind === 'client' && eligibleCompanies.length === 0 && <p className="text-sm text-neutral-600">All eligible clients already have books in this organization.</p>}
      <Button type="submit" disabled={saving || disabled || (kind === 'client' && eligibleCompanies.length === 0)}>{saving ? 'Creating…' : 'Create book'}</Button>
    </form>}
    </div>
  );
}
