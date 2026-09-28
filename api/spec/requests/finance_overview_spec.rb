# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Financial book overview", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:book) { company.organization.finance_books.find_by!(is_default: true) }

  before do
    allow_any_instance_of(Api::V1::Admin::FinanceOverviewsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::FinanceOverviewsController).to receive(:current_company_id).and_return(company.id)
  end

  it "separates balances from recorded cash and excludes another book" do
    invoice = create(:invoice, :with_line_item, :generated, company: company, organization: company.organization,
                     due_date: Date.new(2026, 9, 1))
    InvoicePaymentService.record!(invoice: invoice, actor: actor, amount: 100, received_on: Date.new(2026, 9, 2),
                                  payment_method: "ach", currency: "USD")
    vendor = ExpenseVendor.create!(organization: company.organization, finance_book: book, name: "Vendor")
    expense = Expense.create!(organization: company.organization, finance_book: book, expense_vendor: vendor,
                              category: "Software", description: "Service", expense_on: Date.new(2026, 9, 1),
                              due_on: Date.new(2026, 9, 10), total_amount: 75, currency: "USD")
    ExpensePaymentService.record!(expense: expense, actor: actor, amount: 25, paid_on: Date.new(2026, 9, 2),
                                  payment_method: "card", reference_number: "card-1")
    other_book = company.organization.finance_books.create!(name: "Other", legal_name: "Other", kind: "organization")
    other_vendor = ExpenseVendor.create!(organization: company.organization, finance_book: other_book, name: "Other vendor")
    Expense.create!(organization: company.organization, finance_book: other_book, expense_vendor: other_vendor,
                    category: "Software", description: "Private", expense_on: Date.new(2026, 9, 1),
                    total_amount: 500, currency: "USD")

    get "/api/v1/admin/finance_overview", params: { as_of: "2026-09-29" },
        headers: { "X-Organization-Id" => company.organization_id.to_s, "X-Finance-Book-Id" => book.id.to_s }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["finance_book_id"]).to eq(book.id)
    expect(response.parsed_body.fetch("currencies")).to eq([ {
      "currency" => "USD", "receivables" => "200.0", "overdue_receivables" => "200.0",
      "payments_received" => "100.0", "payables" => "50.0", "overdue_payables" => "50.0",
      "payments_made" => "25.0", "open_invoice_count" => 1, "overdue_invoice_count" => 1,
      "open_expense_count" => 1, "overdue_expense_count" => 1
    } ])
  end
end
