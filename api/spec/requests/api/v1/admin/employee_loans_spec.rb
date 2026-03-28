require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeLoans", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) do
    create(:employee,
      company: company,
      department: department,
      employment_type: "hourly",
      pay_rate: 20.00
    )
  end
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "loan-admin@example.com",
      name: "Loan Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::EmployeeLoansController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::EmployeeLoansController).to receive(:current_user).and_return(admin_user)
  end

  describe "GET /api/v1/admin/employee_loans" do
    it "orders results by employee name without raising SQL errors" do
      other_employee = create(:employee,
        company: company,
        department: department,
        first_name: "Alice",
        last_name: "Zephyr"
      )
      create(:employee,
        company: company,
        department: department,
        first_name: "Bob",
        last_name: "Anderson"
      ).tap do |second_employee|
        EmployeeLoan.create!(
          employee: second_employee,
          company: company,
          name: "First Loan",
          original_amount: 100.00,
          current_balance: 100.00,
          payment_amount: 10.00,
          status: "active"
        )
      end
      EmployeeLoan.create!(
        employee: other_employee,
        company: company,
        name: "Second Loan",
        original_amount: 100.00,
        current_balance: 100.00,
        payment_amount: 10.00,
        status: "active"
      )

      get "/api/v1/admin/employee_loans"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("loans").map { |loan| loan.fetch("employee_name") }).to eq([
        "Bob Anderson",
        "Alice Zephyr"
      ])
    end
  end

  describe "POST /api/v1/admin/employee_loans" do
    let(:valid_params) do
      {
        employee_loan: {
          employee_id: employee.id,
          name: "Tool Advance",
          original_amount: 150.00,
          payment_amount: 25.00,
          start_date: "2024-02-01",
          status: "active"
        }
      }
    end

    it "creates the loan and initial transaction atomically" do
      expect {
        post "/api/v1/admin/employee_loans", params: valid_params, as: :json
      }.to change(EmployeeLoan, :count).by(1)
        .and change(LoanTransaction, :count).by(1)

      expect(response).to have_http_status(:created)
      loan = EmployeeLoan.last
      expect(loan.loan_transactions.additions.count).to eq(1)
    end

    it "rolls back the loan if the initial transaction write fails" do
      invalid_transaction = LoanTransaction.new
      invalid_transaction.validate

      allow_any_instance_of(LoanTransaction).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(invalid_transaction))

      expect {
        post "/api/v1/admin/employee_loans", params: valid_params, as: :json
      }.not_to change(EmployeeLoan, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(LoanTransaction.count).to eq(0)
    end

    it "persists the loan and opening transaction if payload rendering fails after commit" do
      allow_any_instance_of(Api::V1::Admin::EmployeeLoansController).to receive(:loan_payload)
        .and_raise(StandardError, "payload boom")

      expect {
        post "/api/v1/admin/employee_loans", params: valid_params, as: :json
      }.to raise_error(StandardError, "payload boom")

      expect(EmployeeLoan.count).to eq(1)
      expect(LoanTransaction.count).to eq(1)
    end

    it "rejects employees from another company" do
      foreign_department = create(:department, company: other_company)
      foreign_employee = create(:employee, company: other_company, department: foreign_department)

      post "/api/v1/admin/employee_loans",
        params: {
          employee_loan: valid_params[:employee_loan].merge(employee_id: foreign_employee.id)
        },
        as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
