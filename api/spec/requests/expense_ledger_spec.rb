# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organization expense ledger", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:controllers) do
    [ Api::V1::Admin::ExpenseVendorsController, Api::V1::Admin::ExpensesController,
      Api::V1::Admin::ExpensePaymentsController ]
  end

  before do
    controllers.each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  after do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("expense-ledger"))
  end

  def create_vendor(name: "Pacific Vendor")
    post "/api/v1/admin/expense_vendors", params: { expense_vendor: { name: name } }
    expect(response).to have_http_status(:created), response.body
    ExpenseVendor.find(response.parsed_body.dig("expense_vendor", "id"))
  end

  def create_expense(vendor:, amount: "120.00", source_key: nil)
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Annual subscription",
                 expense_on: "2026-09-28", due_on: "2026-10-15", total_amount: amount,
                 source_key: source_key }
    }
    expect(response).to have_http_status(:created), response.body
    Expense.find(response.parsed_body.dig("expense", "id"))
  end

  it "tracks an open bill, partial and final payments, then a documented reversal" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor)
    expect(response.parsed_body.dig("expense", "balance_due")).to eq("120.0")

    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "20.00", paid_on: "2026-09-28", payment_method: "card", reference_number: "card-1"
    }
    expect(response).to have_http_status(:created), response.body
    payment_id = response.parsed_body.fetch("payment_id")
    expect(response.parsed_body.dig("expense", "payment_status")).to eq("partial")
    expect(response.parsed_body.dig("expense", "balance_due")).to eq("100.0")

    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "100.00", paid_on: "2026-09-29", payment_method: "ach", reference_number: "ach-2"
    }
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("expense", "payment_status")).to eq("paid")
    expect(response.parsed_body.dig("expense", "entry_kind")).to eq("bill")

    get "/api/v1/admin/expenses"
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("0.0")

    post "/api/v1/admin/expenses/#{expense.id}/payments/#{payment_id}/reverse", params: { reason: "Duplicate card record" }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("expense", "balance_due")).to eq("20.0")
    expect(ExpensePayment.find(payment_id).reversal_reason).to eq("Duplicate card record")

    get "/api/v1/admin/expenses"
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("20.0")
  end

  it "records a paid purchase atomically and safely retries the same source key" do
    vendor = create_vendor
    request = {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Paid subscription",
                 expense_on: "2026-09-28", total_amount: "120.00", source_key: "purchase-42" },
      payment: { paid_on: "2026-09-28", payment_method: "card", reference_number: "statement-42" }
    }

    post "/api/v1/admin/expenses", params: request
    expect(response).to have_http_status(:created), response.body
    expense_id = response.parsed_body.dig("expense", "id")
    expect(response.parsed_body.dig("expense", "payment_status")).to eq("paid")
    expect(response.parsed_body.dig("expense", "entry_kind")).to eq("purchase")
    expect(response.parsed_body.dig("expense", "balance_due")).to eq("0.0")
    expect(Expense.find(expense_id).expense_payments.active.count).to eq(1)

    post "/api/v1/admin/expenses", params: request
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["already_exists"]).to be(true)
    expect(Expense.count).to eq(1)
    expect(ExpensePayment.count).to eq(1)

    post "/api/v1/admin/expenses", params: request.deep_merge(payment: { reference_number: "different-statement" })
    expect(response).to have_http_status(:conflict)

    post "/api/v1/admin/expenses", params: request.except(:payment)
    expect(response).to have_http_status(:conflict)
  end

  it "requires a stable source key for a paid purchase" do
    vendor = create_vendor
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Paid subscription",
                 expense_on: "2026-09-28", total_amount: "120.00" },
      payment: { paid_on: "2026-09-28", payment_method: "card", reference_number: "statement-42" }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Expense.count).to eq(0)
    expect(ExpensePayment.count).to eq(0)
  end

  it "filters bills and paid purchases across the list and CSV export" do
    vendor = create_vendor
    bill = create_expense(vendor: vendor, source_key: "bill-kind")
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Paid purchase",
                 expense_on: "2026-09-28", total_amount: "35.00", source_key: "purchase-kind" },
      payment: { paid_on: "2026-09-28", payment_method: "card", reference_number: "statement-kind" }
    }
    expect(response).to have_http_status(:created)
    purchase_id = response.parsed_body.dig("expense", "id")

    get "/api/v1/admin/expenses", params: { kind: "bill" }
    expect(response.parsed_body.fetch("expenses").map { |row| row.fetch("id") }).to eq([ bill.id ])
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("120.0")

    get "/api/v1/admin/expenses", params: { kind: "purchase" }
    expect(response.parsed_body.fetch("expenses").map { |row| row.fetch("id") }).to eq([ purchase_id ])
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("0.0")

    get "/api/v1/admin/expenses/export", params: { kind: "purchase" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("kind", "purchase", "Paid purchase")
    expect(response.body).not_to include("Annual subscription")

    payment_id = Expense.find(purchase_id).expense_payments.first.id
    post "/api/v1/admin/expenses/#{purchase_id}/payments/#{payment_id}/reverse", params: { reason: "Statement correction" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("expense", "entry_kind")).to eq("purchase")
    expect(response.parsed_body.dig("expense", "payment_status")).to eq("open")

    get "/api/v1/admin/expenses", params: { kind: "unknown" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects malformed paid-purchase payment details without inserting records" do
    vendor = create_vendor
    expense = { expense_vendor_id: vendor.id, category: "Software", description: "Paid subscription",
                expense_on: "2026-09-28", total_amount: "120.00", source_key: "malformed-42" }
    [ [ "invalid" ], { paid_on: [ "2026-09-28" ], payment_method: "card", reference_number: "statement-42" } ].each do |payment|
      post "/api/v1/admin/expenses", params: { expense: expense, payment: payment }
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(Expense.count).to eq(0)
    expect(ExpensePayment.count).to eq(0)
  end

  it "accepts an original bill retry after a later payment" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor, source_key: "bill-42")
    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "120.00", paid_on: "2026-09-29", payment_method: "ach", reference_number: "ach-42"
    }
    expect(response).to have_http_status(:created)

    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Annual subscription",
                 expense_on: "2026-09-28", due_on: "2026-10-15", total_amount: "120.00", source_key: "bill-42" }
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["already_exists"]).to be(true)
    expect(response.parsed_body.dig("expense", "payment_status")).to eq("paid")
  end

  it "rolls back a paid purchase when the payment evidence is invalid" do
    vendor = create_vendor
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Paid subscription",
                 expense_on: "2026-09-28", total_amount: "120.00", source_key: "invalid-payment-42" },
      payment: { paid_on: "2026-09-28", payment_method: "unknown", reference_number: "statement-42" }
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Expense.count).to eq(0)
    expect(ExpensePayment.count).to eq(0)
  end

  it "rejects overpayment, payment edits, and voiding an expense with recorded payments" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor)

    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "121.00", paid_on: "2026-09-28", payment_method: "card"
    }
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "20.00", paid_on: "2026-09-28", payment_method: "card"
    }
    expect(response).to have_http_status(:created)

    patch "/api/v1/admin/expenses/#{expense.id}", params: { expense: { total_amount: "130.00" } }
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/admin/expenses/#{expense.id}/void", params: { reason: "Entered twice" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(expense.reload.voided_at).to be_nil
  end

  it "isolates expenses and vendors by organization and returns an existing source key once" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor, source_key: "card-statement-42")
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Annual subscription",
                 expense_on: "2026-09-28", due_on: "2026-10-15", total_amount: "120.00", source_key: "card-statement-42" }
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("expense", "id")).to eq(expense.id)

    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: vendor.id, category: "Software", description: "Different expense",
                 expense_on: "2026-09-28", due_on: "2026-10-15", total_amount: "120.00",
                 source_key: "card-statement-42" }
    }
    expect(response).to have_http_status(:conflict)

    other_org = create(:organization)
    other_vendor = ExpenseVendor.create!(organization: other_org, name: "Other vendor")
    post "/api/v1/admin/expenses", params: {
      expense: { expense_vendor_id: other_vendor.id, category: "Software", description: "Wrong org",
                 expense_on: "2026-09-28", total_amount: "10.00" }
    }
    expect(response).to have_http_status(:unprocessable_entity)

    other_expense = Expense.create!(organization: other_org, expense_vendor: other_vendor, category: "Fees",
                                    description: "Private", expense_on: Date.current, total_amount: 10)
    get "/api/v1/admin/expenses/#{other_expense.id}"
    expect(response).to have_http_status(:not_found)
    expect(Expense.where(organization: company.organization).count).to eq(1)
  end

  it "marks a partially paid past-due expense overdue and rejects non-finite payments" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor)
    expense.update!(due_on: Date.yesterday)
    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "20.00", paid_on: Date.current.iso8601, payment_method: "card"
    }
    expect(response).to have_http_status(:created)
    expect(expense.reload.payment_status).to eq("overdue")

    post "/api/v1/admin/expenses/#{expense.id}/payments", params: {
      amount: "Infinity", paid_on: Date.current.iso8601, payment_method: "card"
    }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "searches and filters the full expense ledger before pagination" do
    vendor = create_vendor(name: "Pacific Software")
    51.times do |index|
      Expense.create!(organization: company.organization, expense_vendor: vendor,
                      category: "Software", description: "Routine bill #{index}",
                      expense_on: Date.new(2026, 9, 1), total_amount: 10)
    end
    target = Expense.create!(organization: company.organization, expense_vendor: vendor,
                             category: "Travel", description: "Rare receipt", reference_number: "NEEDLE-42",
                             expense_on: Date.new(2026, 8, 1), total_amount: 25)

    get "/api/v1/admin/expenses", params: { q: "NEEDLE-42", per_page: 50 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(1)
    expect(response.parsed_body.fetch("expenses").map { |row| row.fetch("id") }).to eq([ target.id ])

    get "/api/v1/admin/expenses/export", params: { q: "NEEDLE-42" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("NEEDLE-42")
    expect(response.body).not_to include("Routine bill")

    get "/api/v1/admin/expenses", params: { status: "paid" }
    expect(response.parsed_body.dig("meta", "total_count")).to eq(0)

    get "/api/v1/admin/expenses", params: { status: "unknown" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "keeps paid, partial, overdue, open, and voided expenses in the correct status views" do
    vendor = create_vendor
    open_bill = create_expense(vendor: vendor)
    paid_bill = create_expense(vendor: vendor)
    partial_bill = create_expense(vendor: vendor)
    overdue_bill = create_expense(vendor: vendor)
    overdue_bill.update!(due_on: Date.yesterday)
    voided_bill = create_expense(vendor: vendor)
    post "/api/v1/admin/expenses/#{voided_bill.id}/void", params: { reason: "Duplicate bill" }
    expect(response).to have_http_status(:ok)

    [ [ paid_bill, "120.00" ], [ partial_bill, "20.00" ], [ overdue_bill, "20.00" ], [ open_bill, "10.00" ] ].each do |bill, amount|
      post "/api/v1/admin/expenses/#{bill.id}/payments", params: {
        amount: amount, paid_on: Date.current.iso8601, payment_method: "card"
      }
      expect(response).to have_http_status(:created)
    end
    reversed_payment = open_bill.expense_payments.first
    post "/api/v1/admin/expenses/#{open_bill.id}/payments/#{reversed_payment.id}/reverse",
         params: { reason: "Incorrect card charge" }
    expect(response).to have_http_status(:ok)

    { "paid" => paid_bill, "partial" => partial_bill, "overdue" => overdue_bill, "open" => open_bill }.each do |status, bill|
      get "/api/v1/admin/expenses", params: { status: status, include_voided: true }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("expenses").map { |row| row.fetch("id") }).to eq([ bill.id ])
    end
  end

  it "uses the selected organization for a platform owner's expense workspace and audit trail" do
    other_org = create(:organization, name: "Shimizu Technology")
    other_company = create(:company, organization: other_org, name: "Shimizu Technology")
    owner = create(:user, company: company, organization: company.organization, role: "super_admin")
    controllers.each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(owner)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(other_company.id)
    end

    vendor = create_vendor(name: "Shimizu supplier")
    expense = create_expense(vendor: vendor)
    expect(vendor.organization_id).to eq(other_org.id)
    expect(expense.organization_id).to eq(other_org.id)
    expect(AuditLog.where(action: "expenses#create").order(:id).last.organization_id).to eq(other_org.id)
  end

  it "stores an original receipt with a verified download and exports safe CSV" do
    vendor = create_vendor(name: "=Potential formula")
    expense = create_expense(vendor: vendor)
    file = Tempfile.new([ "receipt", ".pdf" ])
    file.binmode
    file.write("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/pdf", original_filename: "receipt.pdf")
    post "/api/v1/admin/expenses/#{expense.id}/upload_artifact", params: { file: upload }
    expect(response).to have_http_status(:created), response.body
    artifact_id = response.parsed_body.dig("artifact", "id")

    get "/api/v1/admin/expenses/#{expense.id}/artifacts/#{artifact_id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to start_with("%PDF-1.4")

    get "/api/v1/admin/expenses/export"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("'=Potential formula")
  ensure
    file&.close!
  end

  it "does not attach new receipts to voided expenses" do
    vendor = create_vendor
    expense = create_expense(vendor: vendor)
    post "/api/v1/admin/expenses/#{expense.id}/void", params: { reason: "Entered in error" }
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/expenses/#{expense.id}/upload_artifact"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(expense.expense_artifacts.count).to eq(0)
  end
end
