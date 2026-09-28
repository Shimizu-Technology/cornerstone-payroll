// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FinanceBookGate, FinanceBookSelector, useFinanceBook } from './FinanceBookContext';

const { auth, company, listBooks, createBook, setBookId } = vi.hoisted(() => ({
  auth: vi.fn(),
  company: vi.fn(),
  listBooks: vi.fn(),
  createBook: vi.fn(),
  setBookId: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => auth() }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => company() }));
vi.mock('@/services/api', () => ({
  financeBooksApi: { list: listBooks, create: createBook },
  setActiveFinanceBookId: setBookId,
}));

function CurrentBook() {
  const { activeBook } = useFinanceBook();
  return <p>Current book ID: {activeBook.id}</p>;
}

const books = [
  { id: 1, organization_id: 7, company_id: null, name: 'Firm', legal_name: 'Firm LLC', kind: 'organization', is_default: true },
  { id: 2, organization_id: 7, company_id: 5, name: 'Client', legal_name: 'Client LLC', kind: 'client', is_default: false },
];

describe('FinanceBookGate', () => {
  afterEach(cleanup);
  beforeEach(() => {
    localStorage.clear();
    auth.mockReturnValue({ user: { id: 42, organization_id: 7 } });
    company.mockReturnValue({ activeOrganizationId: 7, loading: false, companies: [] });
    listBooks.mockReset();
    createBook.mockReset();
    setBookId.mockReset();
    listBooks.mockResolvedValue({ finance_books: books, effective_finance_book_id: 1 });
  });

  it('validates a stale saved book and switches the active request scope', async () => {
    localStorage.setItem('finance-book:v1:42:7', '999');
    render(<FinanceBookGate><FinanceBookSelector /><CurrentBook /></FinanceBookGate>);

    expect(await screen.findByText('Current book ID: 1')).toBeTruthy();
    expect(localStorage.getItem('finance-book:v1:42:7')).toBe('1');
    fireEvent.change(screen.getByRole('combobox', { name: 'Switch financial book' }), { target: { value: '2' } });
    expect(await screen.findByText('Current book ID: 2')).toBeTruthy();
    expect(localStorage.getItem('finance-book:v1:42:7')).toBe('2');
    expect(setBookId).toHaveBeenCalledWith(2);
  });

  it('does not mount finance actions before the book list resolves', async () => {
    let finish: ((value: unknown) => void) | undefined;
    listBooks.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    render(<FinanceBookGate><CurrentBook /></FinanceBookGate>);

    expect(screen.queryByText(/Current book ID/)).toBeNull();
    expect(screen.getByText('Loading finance books…')).toBeTruthy();
    finish?.({ finance_books: books, effective_finance_book_id: 1 });
    await waitFor(() => expect(screen.getByText('Current book ID: 1')).toBeTruthy());
  });

  it('creates a client book only with a company in the selected organization', async () => {
    auth.mockReturnValue({ user: { id: 42, organization_id: 7, role: 'org_admin' } });
    company.mockReturnValue({ activeOrganizationId: 7, loading: false, companies: [
      { id: 7, name: 'Available Client', organization_id: 7, test_workspace: false },
      { id: 6, name: 'Other Organization Client', organization_id: 8, test_workspace: false },
    ] });
    createBook.mockResolvedValue({ finance_book: { id: 3, organization_id: 7, company_id: 7,
      name: 'Available Client', legal_name: 'Available Client LLC', kind: 'client', is_default: false } });
    render(<FinanceBookGate><FinanceBookSelector /><CurrentBook /></FinanceBookGate>);
    await screen.findByText('Current book ID: 1');

    fireEvent.click(screen.getByRole('button', { name: 'Add financial book' }));
    const companySelect = screen.getByRole('combobox', { name: 'Client company' });
    expect(companySelect.textContent).toContain('Available Client');
    expect(companySelect.textContent).not.toContain('Other Organization Client');
    fireEvent.change(companySelect, { target: { value: '7' } });
    fireEvent.change(screen.getByRole('textbox', { name: 'Book name' }), { target: { value: 'Available Client' } });
    fireEvent.change(screen.getByRole('textbox', { name: 'Legal name' }), { target: { value: 'Available Client LLC' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create book' }));

    expect(await screen.findByText('Current book ID: 3')).toBeTruthy();
    expect(createBook).toHaveBeenCalledWith({ name: 'Available Client', legal_name: 'Available Client LLC', kind: 'client', company_id: 7 });
  });
});
