# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Live finance guards in payroll test context", type: :request do
  let(:home) { create(:company) }
  let(:workspace) { create(:company, organization: home.organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_source_company: home, migration_rehearsal_status: "ready", test_workspace_expires_at: 10.days.from_now) }
  let(:admin) { create(:user, company: home, organization: home.organization, role: "admin") }
  let(:book) { FinanceBook.default_for!(home.organization) }
  let(:headers) { { "X-Company-Id" => workspace.id.to_s, "X-Organization-Id" => home.organization_id.to_s, "X-Finance-Book-Id" => book.id.to_s } }
  before do
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user).and_return(admin)
  end

  [
    [ :post, "/api/v1/admin/invoices" ],
    [ :post, "/api/v1/admin/invoices/import" ],
    [ :post, "/api/v1/admin/invoices/999/issue" ],
    [ :patch, "/api/v1/admin/invoices/999/deliveries/999" ],
    [ :post, "/api/v1/admin/invoices/999/payments" ],
    [ :post, "/api/v1/admin/invoices/999/credit_notes" ],
    [ :post, "/api/v1/admin/expenses" ],
    [ :patch, "/api/v1/admin/expenses/999" ],
    [ :post, "/api/v1/admin/expenses/999/upload_artifact" ],
    [ :post, "/api/v1/admin/expenses/999/payments" ],
    [ :post, "/api/v1/admin/expense_vendors" ],
    [ :post, "/api/v1/admin/invoice_recipients" ],
    [ :post, "/api/v1/admin/invoice_billing_profiles" ],
    [ :post, "/api/v1/admin/invoice_billing_profiles/999/logo" ],
    [ :post, "/api/v1/admin/invoice_recurrences" ],
    [ :post, "/api/v1/admin/invoice_send_schedules" ],
    [ :post, "/api/v1/admin/invoice_chat_sessions" ],
    [ :post, "/api/v1/admin/invoice_chat_sessions/999/message" ],
    [ :post, "/api/v1/admin/invoice_chat_sessions/999/confirm" ],
    [ :post, "/api/v1/admin/finance_books" ],
    [ :post, "/api/v1/admin/finance_api_tokens" ]
  ].each do |method, path|
    it "rejects #{method.to_s.upcase} #{path} before data or provider work" do
      expected_headers = headers
      business_counts = -> { [ Invoice.count, Expense.count, InvoiceRecipient.count, InvoiceBillingProfile.count, ExpenseVendor.count, InvoiceChatSession.count, FinanceBook.count, FinanceApiToken.count ] }
      expect { public_send(method, path, params: {}, headers: expected_headers) }.not_to change(&business_counts)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to include("finance book contains live records", "Select a live client")
    end
  end

  it "keeps existing book and invoice reads available without creating a book" do
    expected_headers = headers
    expect { get "/api/v1/admin/finance_books", headers: expected_headers }.not_to change(FinanceBook, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("finance_books").pluck("id")).to include(book.id)
    get "/api/v1/admin/invoices", headers: expected_headers
    expect(response).to have_http_status(:ok)
  end
end
