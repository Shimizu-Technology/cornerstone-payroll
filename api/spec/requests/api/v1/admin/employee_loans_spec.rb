require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeLoans", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:deduction_type) do
    DeductionType.create!(
      company: company,
      name: "Employee Loan",
      category: "post_tax",
      sub_category: "loan",
      active: true
    )
  end
  let!(:foreign_deduction_type) do
    DeductionType.create!(
      company: other_company,
      name: "Foreign Loan",
      category: "post_tax",
      sub_category: "loan",
      active: true
    )
  end
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

    it "surfaces recurring loan deductions that do not have a balance ledger" do
      employee.employee_deductions.create!(
        deduction_type: deduction_type,
        amount: 50,
        is_percentage: false,
        active: true
      )

      get "/api/v1/admin/employee_loans"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("setup_gaps")).to contain_exactly(
        include(
          "kind" => "employee_deduction",
          "employee_id" => employee.id,
          "label" => "Employee Loan",
          "amount" => "50.0",
          "amount_type" => "fixed",
          "tracked" => false
        )
      )
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
          deduction_type_id: deduction_type.id,
          status: "active"
        }
      }
    end

    it "creates an automatic schedule whose payment and first payday are explicit" do
      post "/api/v1/admin/employee_loans", params: {
        employee_loan: valid_params[:employee_loan].merge(schedule_kind: "new", first_deduction_date: "2026-09-10")
      }, as: :json
      expect(response).to have_http_status(:created)
      loan = EmployeeLoan.last
      schedule = employee.employee_deductions.find_by!(deduction_type: loan.deduction_type)
      expect(schedule.amount).to eq(25)
      expect(loan.first_deduction_date).to eq(Date.new(2026, 9, 10))
      patch "/api/v1/admin/employee_loans/#{loan.id}", params: { employee_loan: { payment_amount: 40, first_deduction_date: "2026-09-24" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(schedule.reload.amount).to eq(40)
      expect(loan.reload.first_deduction_date).to eq(Date.new(2026, 9, 24))
    end

    it "rejects an automatic schedule without a first deduction payday atomically" do
      expect {
        post "/api/v1/admin/employee_loans", params: { employee_loan: valid_params[:employee_loan].merge(schedule_kind: "new") }, as: :json
      }.not_to change(EmployeeLoan, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "converts a verified recurring loan default atomically instead of duplicating it" do
      employee.update!(default_payroll_adjustments: [ { label: "Loan - Installment", amount: 250, treatment: "post_tax_deduction", active: true, notes: "Until paid" } ])
      get "/api/v1/admin/employee_loans"
      gap = response.parsed_body.fetch("setup_gaps").find { |row| row["kind"] == "recurring_adjustment" }
      expect(gap).to be_present
      post "/api/v1/admin/employee_loans", params: { employee_loan: {
        employee_id: employee.id, name: "Verified installment", balance_setup_mode: "existing_balance",
        opening_balance: 650, balance_as_of: "2026-09-01", balance_source: "statement",
        payment_amount: 250, first_deduction_date: "2026-09-10", schedule_kind: gap["kind"],
        schedule_id: gap["id"], schedule_fingerprint: gap["source_fingerprint"]
      } }, as: :json
      expect(response).to have_http_status(:created)
      expect(employee.reload.active_payroll_adjustments).to be_empty
      expect(employee.employee_deductions.active.sum(:amount)).to eq(250)
      expect(AuditLog.last.action).to eq("employee_loans#replace_recurring_deduction")
    end

    it "blocks conversion when a saved manual paycheck would keep the old deduction" do
      adjustment = { "label" => "Loan", "amount" => 250, "treatment" => "post_tax_deduction", "active" => true }
      employee.update!(default_payroll_adjustments: [ adjustment ])
      period = create(:pay_period, company: company)
      create(:payroll_item, employee: employee, company: company, pay_period: period, payroll_adjustments: [ adjustment.merge("amount" => 200) ], custom_columns_data: { "payroll_adjustments_overridden" => true })
      get "/api/v1/admin/employee_loans"
      gap = response.parsed_body.fetch("setup_gaps").find { |row| row["kind"] == "recurring_adjustment" }
      post "/api/v1/admin/employee_loans", params: { employee_loan: valid_params[:employee_loan].merge(
        schedule_kind: gap["kind"], schedule_id: gap["id"], schedule_fingerprint: gap["source_fingerprint"], first_deduction_date: "2026-09-10"
      ) }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Remove that old deduction")
      expect(EmployeeLoan.count).to eq(0)
      expect(employee.reload.active_payroll_adjustments.size).to eq(1)
    end

    it "rejects a stale recurring source without changing setup or creating a balance" do
      employee.update!(default_payroll_adjustments: [ { label: "Loan", amount: 250, treatment: "post_tax_deduction", active: true } ])
      expect {
        post "/api/v1/admin/employee_loans", params: { employee_loan: valid_params[:employee_loan].merge(
          schedule_kind: "recurring_adjustment", schedule_id: 1, schedule_fingerprint: "stale", first_deduction_date: "2026-09-10"
        ) }, as: :json
      }.not_to change(EmployeeLoan, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload.active_payroll_adjustments.size).to eq(1)
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

    it "creates a recurring deduction without inventing a loan balance" do
      expect {
        post "/api/v1/admin/employee_loans", params: {
          employee_loan: {
            employee_id: employee.id,
            name: "Loan until client stops",
            tracking_mode: "recurring_no_balance",
            payment_amount: 50,
            first_deduction_date: "2026-09-15",
            schedule_kind: "new"
          }
        }, as: :json
      }.to change(EmployeeLoan, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(LoanTransaction.count).to eq(0)
      loan = EmployeeLoan.last
      expect(loan).to have_attributes(
        tracking_mode: "recurring_no_balance",
        original_amount: nil,
        opening_balance: nil,
        current_balance: nil,
        balance_as_of: nil,
        balance_source: nil,
        principal_amount_known: false,
        payment_amount: 50
      )
      expect(employee.employee_deductions.find_by!(deduction_type: loan.deduction_type).amount).to eq(50)
      expect(response.parsed_body.dig("loan", "tracking_mode")).to eq("recurring_no_balance")
    end

    it "requires a recurring deduction schedule and first payday" do
      post "/api/v1/admin/employee_loans", params: {
        employee_loan: {
          employee_id: employee.id,
          name: "Incomplete recurring deduction",
          tracking_mode: "recurring_no_balance",
          payment_amount: 50
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Choose or create a payroll deduction schedule")
      expect(EmployeeLoan).not_to exist(name: "Incomplete recurring deduction")
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

    it "rejects deduction types from another company" do
      post "/api/v1/admin/employee_loans",
        params: {
          employee_loan: valid_params[:employee_loan].merge(deduction_type_id: foreign_deduction_type.id)
        },
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq("Deduction type not found")
    end

    it "creates a verified opening balance without inventing an original principal" do
      schedule = employee.employee_deductions.create!(
        deduction_type: deduction_type,
        amount: 50,
        is_percentage: false,
        active: true
      )

      post "/api/v1/admin/employee_loans",
        params: {
          employee_loan: {
            employee_id: employee.id,
            name: "QuickBooks employee loan",
            balance_setup_mode: "existing_balance",
            opening_balance: 425.75,
            balance_as_of: "2026-09-01",
            balance_source: "quickbooks",
            principal_amount_known: false,
            payment_amount: 50,
            schedule_kind: "employee_deduction",
            schedule_id: schedule.id
          }
        },
        as: :json

      expect(response).to have_http_status(:created)
      loan = EmployeeLoan.last
      expect(loan).to have_attributes(
        opening_balance: 425.75,
        current_balance: 425.75,
        original_amount: 425.75,
        balance_as_of: Date.new(2026, 9, 1),
        balance_source: "quickbooks",
        principal_amount_known: false,
        deduction_type_id: deduction_type.id,
        created_by_id: admin_user.id
      )
      expect(loan.loan_transactions.first).to have_attributes(
        amount: 425.75,
        source: "opening_balance",
        recorded_by_id: admin_user.id
      )

      get "/api/v1/admin/employee_loans"
      expect(response.parsed_body.fetch("setup_gaps")).to be_empty
    end

    it "links an assigned loan payroll field to the new balance ledger" do
      definition = PayrollFieldDefinition.create!(
        company: company,
        name: "Employee Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount_type: "fixed",
        default_amount: 50,
        active: true
      )
      assignment = EmployeePayrollField.create!(
        employee: employee,
        payroll_field_definition: definition,
        amount: 50,
        active: true
      )

      post "/api/v1/admin/employee_loans",
        params: {
          employee_loan: {
            employee_id: employee.id,
            name: "Existing loan",
            balance_setup_mode: "existing_balance",
            opening_balance: 200,
            balance_as_of: "2026-09-01",
            balance_source: "statement",
            schedule_kind: "payroll_field",
            schedule_id: assignment.id
          }
        },
        as: :json

      expect(response).to have_http_status(:created)
      expect(assignment.reload.employee_loan).to eq(EmployeeLoan.last)
    end

    it "requires the original principal when staff marks it as known" do
      post "/api/v1/admin/employee_loans",
        params: {
          employee_loan: {
            employee_id: employee.id,
            name: "Existing loan",
            balance_setup_mode: "existing_balance",
            opening_balance: 200,
            balance_as_of: "2026-09-01",
            balance_source: "statement",
            principal_amount_known: true
          }
        },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Original principal must be greater than zero")
      expect(EmployeeLoan).not_to exist(name: "Existing loan")
    end
  end

  describe "PATCH /api/v1/admin/employee_loans/:id" do
    let!(:loan) do
      EmployeeLoan.create!(
        employee: employee,
        company: company,
        deduction_type: deduction_type,
        name: "Tool Advance",
        original_amount: 150.00,
        current_balance: 150.00,
        payment_amount: 25.00,
        status: "active"
      )
    end

    it "rejects foreign deduction types" do
      patch "/api/v1/admin/employee_loans/#{loan.id}",
        params: {
          employee_loan: {
            deduction_type_id: foreign_deduction_type.id
          }
        },
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq("Deduction type not found")
      expect(loan.reload.deduction_type_id).to eq(deduction_type.id)
    end
  end

  describe "POST /api/v1/admin/employee_loans/:id/mark_paid_off" do
    let!(:loan) do
      EmployeeLoan.create!(
        employee: employee,
        company: company,
        name: "Tool Advance",
        original_amount: 150.00,
        current_balance: 100.00,
        payment_amount: 25.00,
        status: "active"
      )
    end

    it "zeros the balance and records a final payment transaction" do
      expect {
        post "/api/v1/admin/employee_loans/#{loan.id}/mark_paid_off",
          params: { date: "2026-05-20", notes: "Confirmed paid outside payroll" },
          as: :json
      }.to change(LoanTransaction, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(loan.reload.status).to eq("paid_off")
      expect(loan.current_balance).to eq(0)
      expect(loan.paid_off_date).to eq(Date.new(2026, 5, 20))

      transaction = loan.loan_transactions.last
      expect(transaction.transaction_type).to eq("payment")
      expect(transaction.amount).to eq(100)
      expect(transaction.notes).to eq("Confirmed paid outside payroll")
    end

    it "does not overwrite an already paid-off loan or paid_off_date" do
      loan.update!(status: "paid_off", current_balance: 0, paid_off_date: Date.new(2026, 4, 1))

      expect {
        post "/api/v1/admin/employee_loans/#{loan.id}/mark_paid_off",
          params: { date: "2026-05-20" },
          as: :json
      }.not_to change(LoanTransaction, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Loan is already paid off")
      expect(loan.reload.paid_off_date).to eq(Date.new(2026, 4, 1))
    end
  end

  describe "POST /api/v1/admin/employee_loans/:id/suspend and reactivate" do
    let!(:loan) do
      EmployeeLoan.create!(
        employee: employee,
        company: company,
        name: "Tool Advance",
        original_amount: 150.00,
        current_balance: 100.00,
        payment_amount: 25.00,
        status: "active"
      )
    end

    it "suspends and reactivates a loan without changing the balance" do
      post "/api/v1/admin/employee_loans/#{loan.id}/suspend", params: { notes: "Pause deductions" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(loan.reload.status).to eq("suspended")
      expect(loan.current_balance).to eq(100)
      expect(loan.notes).to include("Pause deductions")

      post "/api/v1/admin/employee_loans/#{loan.id}/reactivate", params: { notes: "Resume" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(loan.reload.status).to eq("active")
      expect(loan.current_balance).to eq(100)
      expect(loan.notes).to include("Pause deductions")
      expect(loan.notes).to include("Resume")
    end

    it "does not suspend an already paid-off loan" do
      loan.update!(status: "paid_off", current_balance: 0, paid_off_date: Date.new(2026, 4, 1))

      post "/api/v1/admin/employee_loans/#{loan.id}/suspend", params: { notes: "Pause deductions" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Paid-off loans cannot be suspended")
      expect(loan.reload.status).to eq("paid_off")
      expect(loan.paid_off_date).to eq(Date.new(2026, 4, 1))
    end

    it "does not suspend an already suspended loan" do
      loan.update!(status: "suspended", notes: "Already paused")

      post "/api/v1/admin/employee_loans/#{loan.id}/suspend", params: { notes: "Pause again" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Loan is already suspended")
      expect(loan.reload.status).to eq("suspended")
      expect(loan.notes).to eq("Already paused")
    end

    it "does not reactivate an already active loan" do
      post "/api/v1/admin/employee_loans/#{loan.id}/reactivate", params: { notes: "Resume" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Loan is already active")
      expect(loan.reload.status).to eq("active")
    end
  end

  describe "POST /api/v1/admin/employee_loans/:id/stop" do
    let!(:loan) do
      EmployeeLoan.create!(
        employee: employee,
        company: company,
        deduction_type: deduction_type,
        name: "Recurring employee deduction",
        tracking_mode: "recurring_no_balance",
        payment_amount: 25,
        first_deduction_date: Date.new(2026, 9, 15)
      )
    end
    let!(:schedule) do
      employee.employee_deductions.create!(
        deduction_type: deduction_type,
        amount: 25,
        is_percentage: false,
        active: true
      )
    end

    it "requires a reason, then permanently stops the schedule with actor evidence" do
      post "/api/v1/admin/employee_loans/#{loan.id}/stop", params: { reason: "" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(loan.reload).to be_active
      expect(schedule.reload).to be_active

      post "/api/v1/admin/employee_loans/#{loan.id}/stop",
        params: { reason: "Client confirmed the August check was final" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(loan.reload).to have_attributes(status: "stopped", stopped_by_id: admin_user.id)
      expect(loan.stopped_at).to be_present
      expect(loan.notes).to include("Client confirmed the August check was final")
      expect(schedule.reload).not_to be_active

      post "/api/v1/admin/employee_loans/#{loan.id}/reactivate", params: { notes: "Try again" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("create a new authorized schedule")
    end
  end
end
