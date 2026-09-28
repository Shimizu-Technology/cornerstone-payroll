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

    get "/api/v1/admin/expenses"
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("0.0")

    post "/api/v1/admin/expenses/#{expense.id}/payments/#{payment_id}/reverse", params: { reason: "Duplicate card record" }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("expense", "balance_due")).to eq("20.0")
    expect(ExpensePayment.find(payment_id).reversal_reason).to eq("Duplicate card record")

    get "/api/v1/admin/expenses"
    expect(response.parsed_body.dig("summary", "currencies", 0, "balance_due")).to eq("20.0")
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
