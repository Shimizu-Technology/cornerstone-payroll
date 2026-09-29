# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Financial book isolation", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:first_book) { company.organization.finance_books.find_by!(is_default: true) }
  let!(:second_book) do
    company.organization.finance_books.create!(name: "Client books", legal_name: "Client books", kind: "organization")
  end
  let!(:first_vendor) { ExpenseVendor.create!(organization: company.organization, finance_book: first_book, name: "Shared vendor") }
  let!(:second_vendor) { ExpenseVendor.create!(organization: company.organization, finance_book: second_book, name: "Shared vendor") }
  let!(:second_recipient) do
    InvoiceRecipient.create!(organization: company.organization, finance_book: second_book, name: "Other book customer")
  end
  let!(:second_profile) do
    InvoiceBillingProfile.create!(organization: company.organization, finance_book: second_book,
                                  name: "Other book sender", legal_name: "Other book sender")
  end

  before do
    [ Api::V1::Admin::FinanceBooksController, Api::V1::Admin::InvoicesController,
      Api::V1::Admin::InvoiceRecipientsController, Api::V1::Admin::InvoiceBillingProfilesController,
      Api::V1::Admin::InvoiceSendSchedulesController, Api::V1::Admin::InvoiceReceivablesController,
      Api::V1::Admin::ExpenseVendorsController, Api::V1::Admin::ExpensesController,
      Api::V1::Admin::ExpensePaymentsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def headers_for(book)
    { "X-Organization-Id" => company.organization_id.to_s, "X-Finance-Book-Id" => book.id.to_s }
  end

  it "lists available books and requires a selection when an organization has more than one" do
    get "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("finance_books").map { |book| book.fetch("id") }).to match_array([ first_book.id, second_book.id ])

    get "/api/v1/admin/invoices", headers: { "X-Organization-Id" => company.organization_id.to_s }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Select a financial book")
  end

  it "creates a company book within the selected organization and prevents moving its ownership" do
    post "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s },
         params: { finance_book: { name: "Company books", legal_name: "Company books", kind: "client", company_id: company.id } }
    expect(response).to have_http_status(:created)
    created = FinanceBook.find(response.parsed_body.dig("finance_book", "id"))
    expect(created).to have_attributes(organization_id: company.organization_id, company_id: company.id)

    patch "/api/v1/admin/finance_books/#{created.id}",
          headers: { "X-Organization-Id" => company.organization_id.to_s },
          params: { finance_book: { legal_name: "Company books LLC", company_id: -1 } }
    expect(response).to have_http_status(:ok)
    expect(created.reload).to have_attributes(legal_name: "Company books LLC", company_id: company.id)
  end

  it "keeps invoice customers, sender profiles, and writes inside the selected book" do
    get "/api/v1/admin/invoice_recipients", headers: headers_for(first_book)
    expect(response.parsed_body.fetch("invoice_recipients")).to be_empty
    get "/api/v1/admin/invoice_billing_profiles/#{second_profile.id}", headers: headers_for(first_book)
    expect(response).to have_http_status(:not_found)

    post "/api/v1/admin/invoices", headers: headers_for(first_book), params: {
      invoice: { invoice_recipient_id: second_recipient.id, invoice_billing_profile_id: second_profile.id,
                 invoice_date: Date.current.iso8601,
                 line_items: [ { description: "Work", quantity: 1, rate: 100 } ] }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Invoice.count).to eq(0)
  end

  it "keeps expenses, vendors, and payment access inside the selected book" do
    expense = Expense.create!(organization: company.organization, finance_book: second_book,
                              expense_vendor: second_vendor, description: "Subscription", category: "Software",
                              expense_on: Date.current, total_amount: 90, currency: "USD")
    get "/api/v1/admin/expense_vendors", headers: headers_for(first_book)
    expect(response.parsed_body.fetch("expense_vendors").map { |row| row.fetch("id") }).to eq([ first_vendor.id ])
    get "/api/v1/admin/expenses/#{expense.id}", headers: headers_for(first_book)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/admin/expenses/#{expense.id}/payments", headers: headers_for(first_book),
         params: { amount: 90, paid_on: Date.current.iso8601, payment_method: "card" }
    expect(response).to have_http_status(:not_found)
    expect(expense.expense_payments.count).to eq(0)
  end

  it "keeps a personal book private from other staff in the same organization" do
    post "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s },
         params: { finance_book: { name: "My personal finances", legal_name: actor.name, kind: "personal" } }
    expect(response).to have_http_status(:created), response.body
    personal_book = FinanceBook.find(response.parsed_body.dig("finance_book", "id"))
    expect(personal_book).to have_attributes(owner_user_id: actor.id, company_id: nil, kind: "personal")

    get "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s }
    expect(response.parsed_body.fetch("finance_books").map { |row| row.fetch("id") }).to include(personal_book.id)

    other_staff = create(:user, company: company, organization: company.organization, role: "admin")
    other_personal_book = company.organization.finance_books.create!(name: "My personal finances", legal_name: other_staff.name,
                                                                      kind: "personal", owner_user: other_staff)
    [ Api::V1::Admin::FinanceBooksController, Api::V1::Admin::ExpensesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(other_staff)
    end
    get "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s }
    expect(response.parsed_body.fetch("finance_books").map { |row| row.fetch("id") }).not_to include(personal_book.id)
    expect(response.parsed_body.fetch("finance_books").map { |row| row.fetch("id") }).to include(other_personal_book.id)

    get "/api/v1/admin/expenses", headers: headers_for(personal_book)
    expect(response).to have_http_status(:not_found)
    patch "/api/v1/admin/finance_books/#{personal_book.id}",
          headers: { "X-Organization-Id" => company.organization_id.to_s },
          params: { finance_book: { name: "Taken over" } }
    expect(response).to have_http_status(:not_found)
  end

  it "lets a platform admin keep a private book in a selected organization outside their home organization" do
    home_organization = create(:organization)
    home_company = create(:company, organization: home_organization)
    platform_admin = create(:user, company: home_company, organization: home_organization, role: "super_admin")
    allow_any_instance_of(Api::V1::Admin::FinanceBooksController).to receive(:current_user).and_return(platform_admin)

    post "/api/v1/admin/finance_books", headers: { "X-Organization-Id" => company.organization_id.to_s },
         params: { finance_book: { name: "My personal finances", legal_name: platform_admin.name, kind: "personal" } }
    expect(response).to have_http_status(:created), response.body
    expect(FinanceBook.find(response.parsed_body.dig("finance_book", "id")))
      .to have_attributes(organization_id: company.organization_id, owner_user_id: platform_admin.id)
  end
end
