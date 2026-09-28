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
end
