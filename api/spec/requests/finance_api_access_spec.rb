# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Book-scoped finance API access", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:book) { company.organization.finance_books.find_by!(is_default: true) }
  let(:scope_headers) do
    { "X-Organization-Id" => company.organization_id.to_s, "X-Finance-Book-Id" => book.id.to_s }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::FinanceApiTokensController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::FinanceApiTokensController).to receive(:current_company_id).and_return(company.id)
  end

  it "issues a read-only key once and immediately revokes it" do
    post "/api/v1/admin/finance_api_tokens", params: { name: "Shimizu agent" }, headers: scope_headers
    expect(response).to have_http_status(:created), response.body
    secret = response.parsed_body.fetch("secret")
    token_id = response.parsed_body.dig("token", "id")
    expect(secret).to match(/\Acfin_[a-f0-9]{64}\z/)
    expect(FinanceApiToken.find(token_id).token_digest).not_to eq(secret)

    get "/api/v1/admin/finance_api_tokens", headers: scope_headers
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(secret)

    get "/api/v1/finance/context", headers: scope_headers.merge("Authorization" => "Bearer #{secret}")
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("scope")).to eq(
      "organization_id" => company.organization_id, "finance_book_id" => book.id
    )
    expect(response.parsed_body.fetch("scopes")).to eq([ "read" ])

    delete "/api/v1/admin/finance_api_tokens/#{token_id}", headers: scope_headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/finance/context", headers: scope_headers.merge("Authorization" => "Bearer #{secret}")
    expect(response).to have_http_status(:unauthorized)
  end

  it "fails closed for missing and mismatched book context" do
    _token, secret = FinanceApiToken.issue!(finance_book: book, actor: actor, name: "Read-only agent")
    auth = { "Authorization" => "Bearer #{secret}" }

    get "/api/v1/finance/context", headers: auth
    expect(response).to have_http_status(:unprocessable_entity)

    other_book = company.organization.finance_books.create!(name: "Other", legal_name: "Other", kind: "organization")
    get "/api/v1/finance/context", headers: auth.merge(scope_headers).merge("X-Finance-Book-Id" => other_book.id.to_s)
    expect(response).to have_http_status(:forbidden)

    other_organization = create(:organization)
    other_organization.finance_books.create!(name: "Private", legal_name: "Private", kind: "organization")
    get "/api/v1/finance/context", headers: auth.merge(scope_headers).merge("X-Organization-Id" => other_organization.id.to_s)
    expect(response).to have_http_status(:forbidden)

    get "/api/v1/finance/context", headers: auth.merge(scope_headers).merge("X-Organization-Id" => "not-an-id")
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns only the permitted book and rejects use after the creator loses access" do
    _token, secret = FinanceApiToken.issue!(finance_book: book, actor: actor, name: "Read-only agent")
    headers = scope_headers.merge("Authorization" => "Bearer #{secret}")
    invoice = create(:invoice, :with_line_item, company: company, organization: company.organization)
    archived_invoice = create(:invoice, :with_line_item, company: company, organization: company.organization,
                              archived: true, archived_at: Time.current)
    vendor = ExpenseVendor.create!(organization: company.organization, finance_book: book, name: "Vendor")
    expense = Expense.create!(organization: company.organization, finance_book: book, expense_vendor: vendor,
                              category: "Software", description: "Service", expense_on: Date.current, total_amount: 42)
    other_book = company.organization.finance_books.create!(name: "Other", legal_name: "Other", kind: "organization")
    other_vendor = ExpenseVendor.create!(organization: company.organization, finance_book: other_book, name: "Private")
    other_expense = Expense.create!(organization: company.organization, finance_book: other_book,
                                    expense_vendor: other_vendor, category: "Software", description: "Private",
                                    expense_on: Date.current, total_amount: 900)

    get "/api/v1/finance/invoices", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("invoices").map { |row| row.fetch("id") }).to match_array([ invoice.id, archived_invoice.id ])
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    get "/api/v1/finance/expenses", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("expenses").map { |row| row.fetch("id") }).to eq([ expense.id ])
    get "/api/v1/finance/expenses/#{other_expense.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/finance/overview", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("overview", "currencies", 0, "payables")).to eq("42.0")

    actor.update!(active: false)
    get "/api/v1/finance/context", headers: headers
    expect(response).to have_http_status(:unauthorized)

    new_organization = create(:organization)
    new_company = create(:company, organization: new_organization)
    actor.update!(active: true, organization: new_organization, company: new_company)
    get "/api/v1/finance/context", headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects expired keys and cannot use a service key on Clerk routes" do
    token, secret = FinanceApiToken.issue!(finance_book: book, actor: actor, name: "Temporary")
    headers = scope_headers.merge("Authorization" => "Bearer #{secret}")
    token.update!(expires_at: 1.minute.ago)
    get "/api/v1/finance/context", headers: headers
    expect(response).to have_http_status(:unauthorized)

    allow_any_instance_of(Api::V1::Admin::FinanceBooksController).to receive(:auth_disabled?).and_return(false)
    allow_any_instance_of(Api::V1::Admin::FinanceBooksController).to receive(:verify_clerk_token).and_return(nil)
    get "/api/v1/admin/finance_books", headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "invalidates a personal book key if its creator no longer owns the book" do
    personal_book = company.organization.finance_books.create!(name: "Personal", legal_name: actor.name,
                                                                kind: "personal", owner_user: actor)
    _token, secret = FinanceApiToken.issue!(finance_book: personal_book, actor: actor, name: "Personal agent")
    personal_headers = scope_headers.merge("X-Finance-Book-Id" => personal_book.id.to_s,
                                            "Authorization" => "Bearer #{secret}")
    get "/api/v1/finance/context", headers: personal_headers
    expect(response).to have_http_status(:ok)

    new_owner = create(:user, company: company, organization: company.organization, role: "admin")
    personal_book.update_column(:owner_user_id, new_owner.id)
    get "/api/v1/finance/context", headers: personal_headers
    expect(response).to have_http_status(:unauthorized)
  end

  describe "draft invoice writes" do
    let!(:recipient) { create(:invoice_recipient, company: company, organization: company.organization, finance_book: book) }
    let!(:profile) { create(:invoice_billing_profile, organization: company.organization, finance_book: book) }
    let(:draft) do
      { invoice_recipient_id: recipient.id, invoice_billing_profile_id: profile.id,
        invoice_date: "2026-09-29", due_date: "2026-10-29", discount_type: "percent", discount_value: "10",
        line_items: [ { description: "Development", quantity: "2", rate: "100" } ] }
    end
    let(:write_headers) do
      _token, secret = FinanceApiToken.issue!(finance_book: book, actor: actor, name: "Draft agent",
                                              scopes: %w[read draft_write])
      scope_headers.merge("Authorization" => "Bearer #{secret}", "Idempotency-Key" => "draft-create-001")
    end

    it "creates and safely replays one discounted draft with agent provenance" do
      headers = write_headers
      get "/api/v1/finance/recipients", headers: headers
      expect(response.parsed_body.fetch("recipients").map { |row| row.fetch("id") }).to include(recipient.id)
      get "/api/v1/finance/billing_profiles", headers: headers
      expect(response.parsed_body.fetch("billing_profiles").map { |row| row.fetch("id") }).to include(profile.id)

      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      expect(response).to have_http_status(:created), response.body
      first = response.parsed_body.fetch("invoice")
      expect(first.slice("base_status", "total_amount", "discount_amount", "lock_version")).to eq(
        "base_status" => "draft", "total_amount" => 180.0, "discount_amount" => 20.0, "lock_version" => 0
      )
      expect(first.fetch("finance_book_id")).to eq(book.id)
      expect(InvoiceEvent.find_by!(invoice_id: first.fetch("id"), event_type: "draft_created").metadata)
        .to include("finance_api_token_id" => FinanceApiToken.last.id)

      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("replayed")).to eq(true)
      expect(response.parsed_body.dig("invoice", "id")).to eq(first.fetch("id"))
      expect(Invoice.where(finance_book: book).count).to eq(1)
      expect(InvoiceEvent.where(invoice_id: first.fetch("id"), event_type: "draft_created").count).to eq(1)

      post "/api/v1/finance/invoices", params: { invoice: draft.merge(notes: "Different") }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "rejects read-only keys and cross-book parties" do
      _token, secret = FinanceApiToken.issue!(finance_book: book, actor: actor, name: "Read only")
      headers = scope_headers.merge("Authorization" => "Bearer #{secret}", "Idempotency-Key" => "draft-create-002")
      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)

      other_book = company.organization.finance_books.create!(name: "Other draft book", legal_name: "Other", kind: "organization")
      other_recipient = create(:invoice_recipient, company: company, organization: company.organization, finance_book: other_book)
      post "/api/v1/finance/invoices", params: { invoice: draft.merge(invoice_recipient_id: other_recipient.id) },
           headers: write_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Invoice.where(finance_book: book)).to be_empty

      foreign_invoice = create(:invoice, :with_line_item, company: company, organization: company.organization,
                               finance_book: other_book, invoice_billing_profile: create(:invoice_billing_profile,
                               organization: company.organization, finance_book: other_book),
                               invoice_recipient: other_recipient)
      patch "/api/v1/finance/invoices/#{foreign_invoice.id}", params: { invoice: { notes: "Foreign" } },
            headers: write_headers.merge("Idempotency-Key" => "draft-update-other-book", "X-Invoice-Version" => "0"), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "issues draft permission only when an admin asks for it" do
      post "/api/v1/admin/finance_api_tokens", params: { name: "Draft editor", draft_write: true }, headers: scope_headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("token", "scopes")).to eq(%w[read draft_write])
      expect(response.parsed_body.fetch("secret")).to be_present
    end

    it "requires a unique request key and does not create a sender as a side effect" do
      headers = write_headers
      before_count = InvoiceBillingProfile.count
      post "/api/v1/finance/invoices", params: { invoice: draft.except(:invoice_billing_profile_id) },
           headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(InvoiceBillingProfile.count).to eq(before_count)

      post "/api/v1/finance/invoices", params: { invoice: draft },
           headers: headers.except("Idempotency-Key"), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Invoice.where(finance_book: book)).to be_empty
    end

    it "updates a draft conditionally and replays without another event" do
      headers = write_headers
      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      id = response.parsed_body.dig("invoice", "id")
      version = response.parsed_body.dig("invoice", "lock_version")
      line_id = response.parsed_body.dig("invoice", "line_items", 0, "id")
      patch_headers = headers.merge("Idempotency-Key" => "draft-update-001", "X-Invoice-Version" => version.to_s)
      changes = { notes: "Reviewed draft", line_items: [ { id: line_id, description: "Updated development", quantity: "3", rate: "100" } ] }
      patch "/api/v1/finance/invoices/#{id}", params: { invoice: changes }, headers: patch_headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("invoice", "total_amount")).to eq(270.0)
      expect(response.parsed_body.dig("invoice", "lock_version")).to eq(version + 1)

      patch "/api/v1/finance/invoices/#{id}", params: { invoice: changes }, headers: patch_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("replayed")).to eq(true)
      expect(InvoiceEvent.where(invoice_id: id, event_type: "draft_updated").count).to eq(1)

      patch "/api/v1/finance/invoices/#{id}", params: { invoice: { notes: "Stale" } },
            headers: patch_headers.merge("Idempotency-Key" => "draft-update-002"), as: :json
      expect(response).to have_http_status(:conflict)
      patch "/api/v1/finance/invoices/#{id}", params: { invoice: { line_items: [ { id: 999_999, description: "Foreign" } ] } },
            headers: patch_headers.merge("Idempotency-Key" => "draft-update-003", "X-Invoice-Version" => (version + 1).to_s), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "never edits issued or archived invoices" do
      headers = write_headers
      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      id = response.parsed_body.dig("invoice", "id")
      invoice = Invoice.find(id)
      invoice.update!(status: "open", issued_at: Time.current)
      patch "/api/v1/finance/invoices/#{id}", params: { invoice: { notes: "Too late" } },
            headers: headers.merge("Idempotency-Key" => "draft-update-004", "X-Invoice-Version" => invoice.lock_version.to_s), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invoice.reload.notes).not_to eq("Too late")

      invoice.update!(status: "draft", archived: true, archived_at: Time.current)
      patch "/api/v1/finance/invoices/#{id}", params: { invoice: { notes: "Archived" } },
            headers: headers.merge("Idempotency-Key" => "draft-update-005", "X-Invoice-Version" => invoice.lock_version.to_s), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invoice.reload.notes).not_to eq("Archived")
    end

    it "increments the revision for a line-item-only edit" do
      headers = write_headers
      post "/api/v1/finance/invoices", params: { invoice: draft }, headers: headers, as: :json
      id = response.parsed_body.dig("invoice", "id")
      version = response.parsed_body.dig("invoice", "lock_version")
      item = response.parsed_body.dig("invoice", "line_items", 0)
      changes = { line_items: [ { id: item.fetch("id"), description: "Revised development",
                                  quantity: item.fetch("quantity"), rate: item.fetch("rate") } ] }
      patch_headers = headers.merge("Idempotency-Key" => "draft-update-006", "X-Invoice-Version" => version.to_s)
      patch "/api/v1/finance/invoices/#{id}", params: { invoice: changes }, headers: patch_headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("invoice", "lock_version")).to eq(version + 1)

      patch "/api/v1/finance/invoices/#{id}", params: { invoice: { notes: "Stale writer" } },
            headers: patch_headers.merge("Idempotency-Key" => "draft-update-007"), as: :json
      expect(response).to have_http_status(:conflict)
      expect(Invoice.find(id).notes).not_to eq("Stale writer")
    end
  end
end
