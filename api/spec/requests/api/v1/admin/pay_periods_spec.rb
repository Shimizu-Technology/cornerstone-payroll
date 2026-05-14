# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayPeriods", type: :request do
  let!(:organization) { create(:organization, name: "Pay Period Firm") }
  let!(:company) { Company.create!(name: "Test Company", organization: organization) }
  let!(:department) { Department.create!(name: "Engineering", company: company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "admin-pay-periods-#{company.id}@example.com",
      name: "Pay Period Admin",
      role: "admin",
      active: true
    )
  end
  let!(:employee) do
    Employee.create!(
      company: company,
      department: department,
      first_name: "John",
      last_name: "Doe",
      email: "john@example.com",
      employment_type: "hourly",
      pay_rate: 15.00,
      pay_frequency: "biweekly",
      filing_status: "single",
      allowances: 1,
      address_line1: "123 Payroll Way",
      city: "Hagatna",
      state: "GU",
      zip: "96910",
      status: "active",
      hire_date: Date.today - 1.year
    )
  end
  let!(:pay_period) do
    PayPeriod.create!(
      company: company,
      start_date: Date.today - 14.days,
      end_date: Date.today,
      pay_date: Date.today + 3.days,
      status: "draft"
    )
  end

  before do
    # Stub company_id for tests
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(1)
  end

  describe "GET /api/v1/admin/pay_periods" do
    it "returns all pay periods for the company" do
      get "/api/v1/admin/pay_periods"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["pay_periods"].length).to eq(1)
      expect(json["pay_periods"][0]["status"]).to eq("draft")
    end

    it "includes processing lifecycle fields for list transparency" do
      committed_at = Time.zone.parse("2026-03-30 05:00:06")
      pay_period.update!(status: "committed", committed_at: committed_at, created_by_id: admin_user.id)
      AuditLog.create!(
        user: admin_user,
        company: company,
        action: "pay_periods#commit",
        record_type: "pay_periods",
        record_id: pay_period.id,
        metadata: {},
        created_at: committed_at + 1.second
      )

      get "/api/v1/admin/pay_periods"

      json = JSON.parse(response.body)
      period = json["pay_periods"].first
      expect(period["processed_at"]).to be_present
      expect(period["processed_by_name"]).to eq("Pay Period Admin")
      expect(period.dig("lifecycle", "created", "actor_name")).to eq("Pay Period Admin")
      expect(period.dig("lifecycle", "committed", "actor_name")).to eq("Pay Period Admin")
      expect(period.dig("lifecycle", "committed")).not_to have_key("actor_id")
      expect(period.dig("lifecycle", "committed")).not_to have_key("actor_email")
    end

    it "does not expose creator names from unrelated companies" do
      other_company = Company.create!(name: "Other Company", organization: create(:organization, name: "Other Firm"))
      other_user = User.create!(
        company: other_company,
        email: "other-creator@example.com",
        name: "Other Creator",
        role: "manager",
        active: true
      )
      pay_period.update!(created_by_id: other_user.id)

      get "/api/v1/admin/pay_periods"

      period = JSON.parse(response.body)["pay_periods"].first
      expect(period.dig("lifecycle", "created", "actor_name")).to be_nil
    end

    it "filters by status" do
      PayPeriod.create!(company: company, start_date: Date.today - 28.days, end_date: Date.today - 14.days, pay_date: Date.today - 11.days, status: "committed")

      get "/api/v1/admin/pay_periods", params: { status: "draft" }

      json = JSON.parse(response.body)
      expect(json["pay_periods"].length).to eq(1)
      expect(json["pay_periods"][0]["status"]).to eq("draft")
    end

    it "orders by pay period chronology instead of pay date chronology" do
      pay_period.destroy!

      mar_1_original = PayPeriod.create!(
        company: company,
        start_date: Date.new(2026, 3, 1),
        end_date: Date.new(2026, 3, 15),
        pay_date: Date.new(2026, 3, 30),
        status: "committed"
      )
      mar_1_correction = PayPeriod.create!(
        company: company,
        start_date: Date.new(2026, 3, 1),
        end_date: Date.new(2026, 3, 15),
        pay_date: Date.new(2026, 3, 30),
        status: "committed"
      )
      mar_16 = PayPeriod.create!(
        company: company,
        start_date: Date.new(2026, 3, 16),
        end_date: Date.new(2026, 3, 31),
        pay_date: Date.new(2026, 4, 16),
        status: "committed"
      )
      apr_1 = PayPeriod.create!(
        company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 15),
        pay_date: Date.new(2026, 4, 15),
        status: "committed"
      )

      get "/api/v1/admin/pay_periods"

      ids = response.parsed_body.fetch("pay_periods").map { |period| period.fetch("id") }
      expect(ids).to eq([ mar_1_correction.id, mar_1_original.id, mar_16.id, apr_1.id ])
    end
  end

  describe "GET /api/v1/admin/pay_periods/:id" do
    it "returns the pay period with payroll items" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["pay_period"]["id"]).to eq(pay_period.id)
      expect(json["pay_period"]).to have_key("payroll_items")
    end

    it "returns audit-backed lifecycle events" do
      AuditLog.create!(
        user: admin_user,
        company: company,
        action: "pay_periods#run_payroll",
        record_type: "pay_periods",
        record_id: pay_period.id,
        metadata: {}
      )
      AuditLog.create!(
        user: admin_user,
        company: company,
        action: "pay_periods#unapprove",
        record_type: "pay_periods",
        record_id: pay_period.id,
        metadata: {}
      )

      get "/api/v1/admin/pay_periods/#{pay_period.id}"

      json = JSON.parse(response.body)
      expect(json.dig("pay_period", "lifecycle", "created", "timestamp")).to be_present
      expect(json.dig("pay_period", "lifecycle", "calculated", "actor_name")).to eq("Pay Period Admin")
      expect(json.dig("pay_period", "lifecycle", "unapproved", "timestamp")).to be_present
      expect(json.dig("pay_period", "lifecycle", "unapproved")).not_to have_key("actor_id")
      expect(json.dig("pay_period", "lifecycle", "unapproved")).not_to have_key("actor_email")
    end
  end

  describe "POST /api/v1/admin/pay_periods" do
    it "creates a new pay period" do
      params = {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days
        }
      }

      expect {
        post "/api/v1/admin/pay_periods", params: params
      }.to change(PayPeriod, :count).by(1)

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["pay_period"]["status"]).to eq("draft")
    end

    it "optionally updates the company starting check number" do
      company.update!(next_check_number: 1000)

      post "/api/v1/admin/pay_periods", params: {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days,
          starting_check_number: "1250"
        }
      }

      expect(response).to have_http_status(:created)
      expect(company.reload.next_check_number).to eq(1250)
    end

    it "rejects a starting check number that moves the sequence backward" do
      company.update!(next_check_number: 1000)

      expect {
        post "/api/v1/admin/pay_periods", params: {
          pay_period: {
            start_date: Date.today,
            end_date: Date.today + 14.days,
            pay_date: Date.today + 17.days,
            starting_check_number: "999"
          }
        }
      }.not_to change(PayPeriod, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/cannot move backward/i)
    end

    it "returns company validation errors when starting check number save fails" do
      invalid_company = company
      invalid_company.errors.add(:next_check_number, "is invalid")
      allow_any_instance_of(Company).to receive(:update!)
        .and_raise(ActiveRecord::RecordInvalid.new(invalid_company))

      post "/api/v1/admin/pay_periods", params: {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days,
          starting_check_number: "1250"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["errors"]).to include("Next check number is invalid")
    end

    it "returns errors for invalid data" do
      params = {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today - 1.day, # End before start
          pay_date: Date.today + 17.days
        }
      }

      post "/api/v1/admin/pay_periods", params: params

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/admin/pay_periods/:id" do
    it "updates a draft pay period" do
      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { notes: "Updated notes" }
      }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.notes).to eq("Updated notes")
    end

    it "cannot update a committed pay period" do
      pay_period.update!(status: "committed")

      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { notes: "Try to update" }
      }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rolls back date changes if reverting a non-draft period to draft fails" do
      original_pay_date = pay_period.pay_date
      pay_period.update!(status: "approved", approved_at: 1.hour.ago, approved_by_id: admin_user.id)

      allow_any_instance_of(PayPeriod).to receive(:update!).and_wrap_original do |method, *args|
        attrs = args.first || {}
        raise ActiveRecord::RecordInvalid.new(method.receiver) if attrs[:status] == "draft"

        method.call(*args)
      end

      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { pay_date: original_pay_date + 1.day }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(pay_period.reload).to have_attributes(
        pay_date: original_pay_date,
        status: "approved"
      )
    end
  end

  describe "PATCH /api/v1/admin/pay_periods/:id/correct_pay_date" do
    before do
      allow(PayrollTaxSyncJob).to receive(:perform_later)
    end

    it "corrects a committed pay date and related date-bearing records without changing dollars" do
      old_pay_date = Date.new(2026, 4, 15)
      new_pay_date = Date.new(2026, 4, 30)
      pay_period.update!(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 15),
        pay_date: old_pay_date,
        status: "committed",
        committed_at: Time.current,
        tax_sync_status: "synced",
        tax_synced_at: Time.current
      )
      prior_period = create(
        :pay_period,
        :committed,
        company: company,
        start_date: Date.new(2026, 3, 16),
        end_date: Date.new(2026, 3, 31),
        pay_date: Date.new(2026, 4, 16)
      )
      create(
        :payroll_item,
        :with_check,
        company: company,
        employee: employee,
        pay_period: prior_period,
        gross_pay: 50,
        net_pay: 45,
        withholding_tax: 3,
        social_security_tax: 1,
        medicare_tax: 1,
        ytd_gross: 150,
        ytd_net: 135,
        ytd_withholding_tax: 9,
        ytd_social_security_tax: 3,
        ytd_medicare_tax: 3
      )
      payroll_item = create(
        :payroll_item,
        :with_check,
        company: company,
        employee: employee,
        pay_period: pay_period,
        check_date: old_pay_date,
        gross_pay: 100,
        net_pay: 90,
        withholding_tax: 6,
        social_security_tax: 2,
        medicare_tax: 2,
        ytd_gross: 100,
        ytd_net: 90,
        ytd_withholding_tax: 6,
        ytd_social_security_tax: 2,
        ytd_medicare_tax: 2
      )
      non_employee_check = create(
        :non_employee_check,
        company: company,
        pay_period: pay_period,
        payment_period_type: "pay_period",
        payment_date: old_pay_date
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/correct_pay_date",
        params: {
          pay_date: new_pay_date.iso8601,
          reason: "AIRE payroll was entered with the wrong pay date"
        }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload).to have_attributes(
        pay_date: new_pay_date,
        tax_sync_status: "pending",
        tax_synced_at: nil
      )
      expect(payroll_item.reload).to have_attributes(
        check_date: new_pay_date,
        gross_pay: 100,
        net_pay: 90,
        ytd_gross: 150,
        ytd_net: 135
      )
      expect(prior_period.payroll_items.first.reload).to have_attributes(
        ytd_gross: 50,
        ytd_net: 45
      )
      expect(non_employee_check.reload.payment_date).to eq(new_pay_date)
      expect(AuditLog.last).to have_attributes(
        action: "correct_committed_pay_date",
        record_type: "pay_periods",
        record_id: pay_period.id
      )
      expect(AuditLog.last.metadata).to include(
        "old_pay_date" => old_pay_date.to_s,
        "new_pay_date" => new_pay_date.to_s,
        "reason" => "AIRE payroll was entered with the wrong pay date"
      )
      expect(PayrollTaxSyncJob).to have_received(:perform_later).with(pay_period.id)
    end

    it "rejects pay date corrections outside the original tax year" do
      pay_period.update!(pay_date: Date.new(2026, 12, 31), status: "committed", committed_at: Time.current)

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/correct_pay_date",
        params: { pay_date: "2027-01-02", reason: "Wrong date" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/same tax year/)
    end

    it "requires a reason" do
      pay_period.update!(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 15),
        pay_date: Date.new(2026, 4, 15),
        status: "committed",
        committed_at: Time.current
      )

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/correct_pay_date",
        params: { pay_date: "2026-04-30", reason: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/reason is required/)
    end
  end

  describe "DELETE /api/v1/admin/pay_periods/:id" do
    it "deletes a draft pay period" do
      expect {
        delete "/api/v1/admin/pay_periods/#{pay_period.id}"
      }.to change(PayPeriod, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "cannot delete a committed pay period" do
      pay_period.update!(status: "committed")

      delete "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "deletes a draft correction-run pay period and clears source superseded link" do
      source = PayPeriod.create!(
        company: company,
        start_date: Date.today - 28.days,
        end_date: Date.today - 14.days,
        pay_date: Date.today - 11.days,
        status: "committed",
        correction_status: "voided"
      )
      pay_period.update!(
        correction_status: "correction",
        source_pay_period_id: source.id,
        status: "draft"
      )
      source.update!(superseded_by_id: pay_period.id)

      delete "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(PayPeriod.exists?(pay_period.id)).to eq(false)
      expect(source.reload.superseded_by_id).to be_nil
      expect(body["deleted_correction_run_id"]).to eq(pay_period.id)
      expect(body["source_pay_period"]["id"]).to eq(source.id)

      deletion_event = PayPeriodCorrectionEvent.where(action_type: "correction_run_deleted")
                                               .order(:id)
                                               .last
      expect(deletion_event).to be_present
      expect(deletion_event.pay_period_id).to eq(source.id)
      expect(deletion_event.reason).to eq("Draft correction run deleted by operator")
      expect(deletion_event.metadata["deleted_correction_run_id"]).to eq(pay_period.id)
    end

    it "blocks deleting non-draft correction runs" do
      source = PayPeriod.create!(
        company: company,
        start_date: Date.today - 28.days,
        end_date: Date.today - 14.days,
        pay_date: Date.today - 11.days,
        status: "committed",
        correction_status: "voided"
      )
      pay_period.update!(
        correction_status: "correction",
        source_pay_period_id: source.id,
        status: "committed"
      )

      delete "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/only delete draft correction run/i)
    end

    it "returns 422 for orphaned draft correction run delete" do
      source = PayPeriod.create!(
        company: company,
        start_date: Date.today - 28.days,
        end_date: Date.today - 14.days,
        pay_date: Date.today - 11.days,
        status: "committed",
        correction_status: "voided"
      )
      pay_period.update!(
        correction_status: "correction",
        source_pay_period_id: source.id,
        status: "draft"
      )
      pay_period.update_column(:source_pay_period_id, nil)

      delete "/api/v1/admin/pay_periods/#{pay_period.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/orphaned correction run/i)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/run_payroll" do
    before do
      # Create tax tables for calculations (use find_or_create to avoid uniqueness conflicts)
      TaxTable.find_or_create_by!(
        tax_year: Date.today.year,
        filing_status: "single",
        pay_frequency: "biweekly"
      ) do |t|
        t.ss_rate = 0.062
        t.ss_wage_base = 184500.00
        t.medicare_rate = 0.0145
        t.allowance_amount = 192.31
        t.bracket_data = [
          { min_income: 0, max_income: 476.92, rate: 0.10, base_tax: 0, threshold: 0 },
          { min_income: 476.93, max_income: 1938.46, rate: 0.12, base_tax: 47.69, threshold: 476.93 },
          { min_income: 1938.47, max_income: 999999999, rate: 0.22, base_tax: 223.07, threshold: 1938.47 }
        ]
      end
    end

    it "calculates payroll for all active employees" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["results"]["success"].length).to eq(1)
      expect(json["pay_period"]["status"]).to eq("calculated")
      expect(pay_period.reload.payroll_items.count).to eq(1)
    end

    it "clears stale unapproval lifecycle metadata when payroll is recalculated" do
      pay_period.update!(
        status: "calculated",
        unapproved_at: 1.day.ago,
        unapproved_by_id: admin_user.id
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload).to have_attributes(
        status: "calculated",
        unapproved_at: nil,
        unapproved_by_id: nil
      )
    end

    it "calculates with custom hours" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: {
          employee.id.to_s => { regular: 80, overtime: 10 }
        }
      }

      expect(response).to have_http_status(:ok)
      item = pay_period.reload.payroll_items.first
      expect(item.hours_worked).to eq(80)
      expect(item.overtime_hours).to eq(10)
    end

    it "stores YTD values as of the pay date and excludes later committed payroll" do
      pay_period.update!(
        start_date: Date.new(Date.today.year, 1, 1),
        end_date: Date.new(Date.today.year, 1, 14),
        pay_date: Date.new(Date.today.year, 1, 17)
      )

      later_period = PayPeriod.create!(
        company: company,
        start_date: Date.new(Date.today.year, 2, 1),
        end_date: Date.new(Date.today.year, 2, 14),
        pay_date: Date.new(Date.today.year, 2, 17),
        status: "committed",
        committed_at: Time.current
      )

      PayrollItem.create!(
        pay_period: later_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 10,
        gross_pay: 150.00,
        net_pay: 120.00,
        withholding_tax: 10.00,
        social_security_tax: 9.30,
        medicare_tax: 2.18
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: {
          employee.id.to_s => { regular: 80, overtime: 0 }
        }
      }

      expect(response).to have_http_status(:ok)

      item = pay_period.reload.payroll_items.first
      expect(item.gross_pay.to_f).to eq(1200.0)
      expect(item.ytd_gross.to_f).to eq(1200.0)
      expect(item.ytd_withholding_tax.to_f).to eq(item.withholding_tax.to_f)
      expect(item.ytd_social_security_tax.to_f).to eq(item.social_security_tax.to_f)
      expect(item.ytd_medicare_tax.to_f).to eq(item.medicare_tax.to_f)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/approve" do
    it "approves a calculated pay period" do
      pay_period.update!(status: "calculated")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/approve"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.status).to eq("approved")
    end

    it "cannot approve a draft pay period" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/approve"

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/commit" do
    before do
      pay_period.update!(status: "approved")
      PayrollItem.create!(
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        gross_pay: 1200.00,
        withholding_tax: 100.00,
        social_security_tax: 74.40,
        medicare_tax: 17.40,
        net_pay: 1008.20
      )
    end

    it "commits an approved pay period and updates YTD" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.status).to eq("committed")
      expect(pay_period.committed_at).to be_present

      # Check YTD was updated
      ytd = EmployeeYtdTotal.find_by(employee: employee, year: pay_period.pay_date.year)
      expect(ytd).to be_present
      expect(ytd.gross_pay).to eq(1200.00)

      company_ytd = CompanyYtdTotal.find_by(company: company, year: pay_period.pay_date.year)
      expect(company_ytd).to be_present
      expect(company_ytd.gross_pay).to eq(1200.00)
    end

    it "registers tax sync enqueue on transaction commit" do
      allow(PayrollTaxSyncJob).to receive(:perform_later)
      allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      expect(ActiveRecord).to have_received(:after_all_transactions_commit)
      expect(PayrollTaxSyncJob).to have_received(:perform_later).with(pay_period.id)
    end

    it "cannot commit when no payroll items exist" do
      pay_period.payroll_items.destroy_all

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("no payroll items")
    end

    it "returns 422 when correction-commit audit validation fails" do
      source = PayPeriod.create!(
        company: company,
        start_date: Date.today - 28.days,
        end_date: Date.today - 14.days,
        pay_date: Date.today - 11.days,
        status: "committed",
        correction_status: "voided"
      )
      pay_period.update!(correction_status: "correction", source_pay_period_id: source.id)

      allow(PayPeriodCorrectionService).to receive(:record_correction_committed!)
        .and_raise(PayPeriodCorrectionService::InvalidStateError, "missing source pay period linkage")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/missing source pay period linkage/)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/commit" do
    before do
      pay_period.update!(status: "approved")
      TaxTable.find_or_create_by!(
        tax_year: pay_period.pay_date.year,
        filing_status: "single",
        pay_frequency: "biweekly"
      ) do |t|
        t.ss_rate = 0.062
        t.ss_wage_base = 184_500.00
        t.medicare_rate = 0.0145
        t.allowance_amount = 192.31
        t.bracket_data = [
          { min_income: 0, max_income: 476.92, rate: 0.10, base_tax: 0, threshold: 0 },
          { min_income: 476.93, max_income: 1938.46, rate: 0.12, base_tax: 47.69, threshold: 476.93 },
          { min_income: 1938.47, max_income: 999999999, rate: 0.22, base_tax: 223.07, threshold: 1938.47 }
        ]
      end
    end

    it "records loan payments when payroll is committed" do
      deduction_type = DeductionType.create!(
        company: company,
        name: "Employee Loan",
        category: "post_tax",
        sub_category: "loan",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: deduction_type,
        amount: 50.0,
        is_percentage: false,
        active: true
      )
      loan = EmployeeLoan.create!(
        employee: employee,
        company: company,
        deduction_type: deduction_type,
        name: "Tool Advance",
        original_amount: 200.0,
        current_balance: 200.0,
        payment_amount: 50.0,
        status: "active"
      )

      payroll_item = PayrollItem.create!(
        pay_period: pay_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        overtime_hours: 0,
        reported_tips: 0,
        bonus: 0
      )
      payroll_item.calculate!

      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"
      }.to change { loan.reload.current_balance }.from(200.0).to(150.0)
        .and change { loan.loan_transactions.payments.count }.by(1)

      expect(response).to have_http_status(:ok)
    end
  end
end
