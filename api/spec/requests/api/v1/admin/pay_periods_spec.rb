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
      ssn_encrypted: "900-70-0010",
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

    it "orders newest pay periods first by period chronology instead of pay date chronology" do
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
      expect(ids).to eq([ apr_1.id, mar_16.id, mar_1_correction.id, mar_1_original.id ])
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/generate_fit_check" do
    before do
      pay_period.update!(status: "committed", committed_at: Time.current)
      company.update!(next_check_number: 8100)
    end

    it "creates a numbered FIT check that is immediately available to print" do
      create(:payroll_item,
        company: company,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        withholding_tax: 43.13,
        additional_withholding: 0,
        voided: false)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/generate_fit_check"

      expect(response).to have_http_status(:ok)
      fit_check = pay_period.non_employee_checks.find_by!(auto_generated_type: "fit_deposit")
      expect(fit_check).to have_attributes(check_number: "8100", check_status: "unprinted")
      expect(company.reload.next_check_number).to eq(8101)
      expect(response.parsed_body).to include(
        "check_number" => "8100",
        "created" => true,
        "number_assigned" => true
      )
    end

    it "repairs an existing unnumbered FIT check when generation is requested again" do
      fit_check = create(:non_employee_check,
        company: company,
        pay_period: pay_period,
        payment_period_type: "pay_period",
        tax_year: nil,
        tax_month: nil,
        auto_generated_type: "fit_deposit",
        check_type: "tax_deposit",
        check_number: nil)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/generate_fit_check"

      expect(response).to have_http_status(:ok)
      expect(fit_check.reload.check_number).to eq("8100")
      expect(response.parsed_body).to include(
        "check_number" => "8100",
        "created" => false,
        "number_assigned" => true
      )
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
      expect(json["pay_period"]["run_purpose"]).to eq("regular")
      expect(json["pay_period"]["includes_base_salary"]).to be(true)
    end

    it "defaults a non-regular run to no base salary" do
      post "/api/v1/admin/pay_periods", params: {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days,
          run_purpose: "bonus"
        }
      }

      expect(response).to have_http_status(:created)
      period = PayPeriod.order(:id).last
      expect(period.run_purpose).to eq("bonus")
      expect(period.includes_base_salary).to be(false)
      expect(period.run_purpose_source).to eq("operator_selected")
    end

    it "rejects base salary on an off-cycle tips run" do
      post "/api/v1/admin/pay_periods", params: {
        pay_period: {
          start_date: Date.today,
          end_date: Date.today + 14.days,
          pay_date: Date.today + 17.days,
          run_purpose: "off_cycle_tips",
          includes_base_salary: true
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("errors").join(" ")).to match(/base salary/i)
    end

    it "records operator intent when a draft run purpose changes" do
      patch "/api/v1/admin/pay_periods/#{pay_period.id}", params: {
        pay_period: { run_purpose: "commission" }
      }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.run_purpose).to eq("commission")
      expect(pay_period.includes_base_salary).to be(false)
      expect(pay_period.run_purpose_source).to eq("operator_selected")
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

    it "allows an unused starting check number that is lower than the current sequence" do
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
      }.to change(PayPeriod, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(company.reload.next_check_number).to eq(999)
    end

    it "rejects a starting check number that has already been used" do
      company.update!(next_check_number: 1000)
      create(:payroll_item, company: company, pay_period: pay_period, employee: employee, check_number: "999")

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
      expect(JSON.parse(response.body)["error"]).to match(/already used/i)
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
          reason: "Pay date was entered with the wrong date"
        }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload).to have_attributes(
        pay_date: new_pay_date,
        tax_sync_status: nil,
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
        record_type: "PayPeriod",
        record_id: pay_period.id
      )
      expect(AuditLog.last.metadata).to include(
        "old_pay_date" => old_pay_date.to_s,
        "new_pay_date" => new_pay_date.to_s,
        "reason" => "Pay date was entered with the wrong date"
      )
      correction = response.parsed_body.dig("pay_period", "pay_date_corrections").last
      expect(correction).to include(
        "old_pay_date" => old_pay_date.to_s,
        "new_pay_date" => new_pay_date.to_s,
        "reason" => "Pay date was entered with the wrong date",
        "corrected_by_name" => admin_user.name
      )
      expect(PayrollTaxSyncJob).not_to have_received(:perform_later)
    end

    it "does not mask a successful correction when audit logging fails" do
      old_pay_date = Date.new(2026, 4, 15)
      new_pay_date = Date.new(2026, 4, 30)
      pay_period.update!(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 15),
        pay_date: old_pay_date,
        status: "committed",
        committed_at: Time.current
      )

      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

      patch "/api/v1/admin/pay_periods/#{pay_period.id}/correct_pay_date",
        params: {
          pay_date: new_pay_date.iso8601,
          reason: "Pay date was entered with the wrong date"
        }

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.pay_date).to eq(new_pay_date)
      expect(response.parsed_body.dig("correction", "old_pay_date")).to eq(old_pay_date.to_s)
      expect(response.parsed_body.dig("correction", "new_pay_date")).to eq(new_pay_date.to_s)
    end

    it "treats same-date submissions as no-ops without writing a correction audit log" do
      pay_date = Date.new(2026, 4, 15)
      pay_period.update!(
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 15),
        pay_date: pay_date,
        status: "committed",
        committed_at: Time.current
      )

      expect {
        patch "/api/v1/admin/pay_periods/#{pay_period.id}/correct_pay_date",
          params: {
            pay_date: pay_date.iso8601,
            reason: "No change needed"
          }
      }.not_to change { AuditLog.where(action: "correct_committed_pay_date").count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("correction", "noop")).to eq(true)
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

  describe "GET /api/v1/admin/pay_periods/:id/comparison" do
    it "returns an ok no-comparison status when no previous committed period exists" do
      PayrollItem.create!(
        company: company,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        gross_pay: 1200.00,
        net_pay: 950.00,
        withholding_tax: 100.00,
        social_security_tax: 74.40,
        medicare_tax: 17.40,
        total_deductions: 250.00
      )

      get "/api/v1/admin/pay_periods/#{pay_period.id}/comparison"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["previous_pay_period"]).to be_nil
      expect(json["employee_changes"]).to eq([])
      expect(json.dig("review_flags", "status")).to eq("ok")
      expect(json.dig("review_flags", "review_count")).to eq(0)
      expect(json.dig("review_flags", "message")).to eq("No previous committed pay period found for comparison.")
    end

    it "compares the period against the previous committed period and returns employee review flags" do
      previous_period = PayPeriod.create!(
        company: company,
        start_date: pay_period.start_date - 14.days,
        end_date: pay_period.end_date - 14.days,
        pay_date: pay_period.pay_date - 14.days,
        status: "committed",
        committed_at: 1.week.ago
      )
      PayrollItem.create!(
        company: company,
        pay_period: previous_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        gross_pay: 1200.00,
        net_pay: 950.00,
        withholding_tax: 100.00,
        social_security_tax: 74.40,
        medicare_tax: 17.40,
        total_deductions: 250.00,
        reported_tips: 0,
        loan_deduction: 0
      )
      PayrollItem.create!(
        company: company,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 80,
        gross_pay: 1500.00,
        net_pay: 1100.00,
        withholding_tax: 125.00,
        social_security_tax: 93.00,
        medicare_tax: 21.75,
        total_deductions: 400.00,
        reported_tips: 250.00,
        loan_deduction: 50.00
      )

      get "/api/v1/admin/pay_periods/#{pay_period.id}/comparison"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json.dig("previous_pay_period", "id")).to eq(previous_period.id)
      expect(json.dig("summary", "gross_pay", "delta")).to eq(300.0)
      expect(json.dig("summary", "reported_tips", "delta")).to eq(250.0)
      expect(json.dig("review_flags", "status")).to eq("review")
      expect(json.dig("review_flags", "warning_count")).to eq(0)
      expect(json.dig("review_flags", "review_count")).to be >= 1
      expect(json.dig("review_flags", "message")).to eq("Review recommended before approval.")
      expect(json["employee_changes"].first["employee_name"]).to eq(employee.full_name)
      expect(json["employee_changes"].first["flags"].map { |flag| flag["key"] }).to include("gross_pay", "reported_tips")
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

    it "resynchronizes a stale contractor snapshot before recalculating a W-2 employee" do
      employee.allow_tax_classification_change = true
      employee.update!(
        employment_type: "contractor",
        contractor_type: "individual",
        contractor_pay_type: "flat_fee"
      )
      stale_item = pay_period.payroll_items.create!(
        company: company,
        employee: employee,
        employment_type: "contractor",
        pay_rate: 175,
        hours_worked: 0,
        gross_pay: 175,
        net_pay: 175
      )
      employee.allow_tax_classification_change = true
      employee.update!(employment_type: "hourly", pay_rate: 15)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: {
          employee.id.to_s => { regular: 8, overtime: 0 }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(stale_item.reload.employment_type).to eq("hourly")
      expect(stale_item.gross_pay).to eq(120.to_d)
      expect(stale_item.social_security_tax).to be_positive
      expect(stale_item.medicare_tax).to be_positive
    end

    it "applies a worksheet payroll-field override on the first calculation" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "MoSa Incentive",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "fixed",
        default_amount: 25,
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 25)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: { employee.id.to_s => { regular: 10, overtime: 0 } },
        payroll_field_inputs: {
          employee.id.to_s => { field.id.to_s => { mode: "override", amount: 40 } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors")).to be_empty
      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      entry = item.payroll_item_field_entries.find_by!(payroll_field_definition: field)
      expect(entry).to have_attributes(source: "manual", amount: 40.to_d)
      expect(item.gross_pay.to_f).to eq(190.0)
    end

    it "calculates a default percentage payroll field from first-run base gross" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "First Run Commission",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "percentage",
        default_percentage: 10,
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, percentage: 10)

      expect(pay_period.payroll_items.where(employee: employee)).not_to exist

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: { employee.id.to_s => { regular: 10, overtime: 0 } },
        payroll_field_inputs: {
          employee.id.to_s => { field.id.to_s => { mode: "default" } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors")).to be_empty
      item = pay_period.reload.payroll_items.find_by!(employee: employee)
      entry = item.payroll_item_field_entries.find_by!(payroll_field_definition: field)
      expect(entry).to have_attributes(source: "employee_default", amount: 15.to_d)
      expect(item.gross_pay).to eq(165.to_d)
    end

    it "does not add an omitted hourly employee to an imported payroll just because worksheet defaults were submitted" do
      omitted_employee = Employee.create!(
        company: company,
        department: department,
        first_name: "Import",
        last_name: "Omitted",
        email: "import-omitted@example.com",
        employment_type: "hourly",
        ssn_encrypted: "900-70-0011",
        pay_rate: 15,
        pay_frequency: "biweekly",
        filing_status: "single",
        allowances: 0,
        status: "active",
        hire_date: 1.year.ago,
        address_line1: "456 Payroll Way",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Company Allowance",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "fixed",
        default_amount: 25,
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: omitted_employee, payroll_field_definition: field, amount: 25)
      pay_period.payroll_items.create!(
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15,
        hours_worked: 10,
        import_source: "mosa_revel"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        hours: { omitted_employee.id.to_s => { regular: 0, overtime: 0 } },
        payroll_field_inputs: {
          omitted_employee.id.to_s => { field.id.to_s => { mode: "default" } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors")).to be_empty
      expect(pay_period.reload.payroll_items.where(employee: omitted_employee)).not_to exist
    end

    it "can return a prior override to the employee default" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Phone Allowance",
        kind: "addition",
        tax_treatment: "non_taxable_addition",
        category: "phone",
        amount_type: "fixed",
        default_amount: 25,
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 25)
      item = pay_period.payroll_items.create!(
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15,
        hours_worked: 10
      )
      item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: field.name,
        kind: field.kind,
        tax_treatment: field.tax_treatment,
        category: field.category,
        amount: 40,
        source: "manual",
        employee_paid: false,
        employer_paid: false,
        active: true
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        payroll_field_inputs: {
          employee.id.to_s => { field.id.to_s => { mode: "default" } }
        }
      }

      expect(response.parsed_body.dig("results", "errors")).to be_empty
      entry = item.reload.payroll_item_field_entries.find_by!(payroll_field_definition: field)
      expect(entry).to have_attributes(source: "employee_default", amount: 25.to_d)
      expect(item.gross_pay).to eq(150.to_d)
      expect(item.net_pay).to eq((item.gross_pay - item.total_deductions + 25).round(2))
    end

    it "rejects a payroll field that is not assigned to the employee" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Unassigned Field",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "other",
        amount_type: "manual",
        show_in_payroll_grid: true
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        payroll_field_inputs: {
          employee.id.to_s => { field.id.to_s => { mode: "override", amount: 20 } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors", 0, "error")).to eq(
        "Payroll field is not assigned to this employee for this pay date"
      )
      expect(pay_period.reload).to be_draft
    end

    it "returns a stable validation error for an invalid payroll field ID" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        payroll_field_inputs: {
          employee.id.to_s => { "not-an-id" => { mode: "override", amount: 20 } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors", 0, "error")).to eq("Payroll field ID is invalid")
      expect(pay_period.reload).to be_draft
    end

    it "rejects a cleared override instead of silently retaining an earlier amount" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Manual Uniform Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "other",
        amount_type: "manual",
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: {
        payroll_field_inputs: {
          employee.id.to_s => { field.id.to_s => { mode: "override", amount: nil } }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "errors", 0, "error")).to eq(
        "Manual Uniform Deduction must be a valid amount"
      )
      expect(pay_period.reload).to be_draft
    end

    it "does not recreate employees excluded from this pay period during recalculation" do
      contractor = Employee.create!(
        company: company,
        first_name: "Asia",
        last_name: "Taylor",
        email: "asia@example.com",
        employment_type: "contractor",
        contractor_type: "individual",
        contractor_pay_type: "flat_fee",
        pay_rate: 175.00,
        pay_frequency: "biweekly",
        status: "active",
        hire_date: Date.today - 1.year,
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Marine Corps Dr",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )
      pay_period.payroll_items.create!(
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 8,
        import_source: "mosa_revel"
      )
      PayPeriodExcludedEmployee.create!(
        pay_period: pay_period,
        employee: contractor,
        excluded_by: admin_user,
        reason: "Removed from pay period"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll"

      expect(response).to have_http_status(:ok)
      pay_period.reload
      expect(pay_period.payroll_items.where(employee_id: contractor.id)).not_to exist
      expect(response.parsed_body.dig("pay_period", "excluded_employee_ids")).to include(contractor.id)
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

  describe "GET /api/v1/admin/pay_periods/:id/payroll_field_inputs" do
    it "returns only active, effective, visible employee assignments for the pay date" do
      visible = PayrollFieldDefinition.create!(
        company: company,
        name: "Company Rent",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount_type: "fixed",
        default_amount: 80,
        show_in_payroll_grid: true,
        sort_order: 2
      )
      hidden = PayrollFieldDefinition.create!(
        company: company,
        name: "Hidden Field",
        kind: "addition",
        tax_treatment: "non_taxable_addition",
        category: "other",
        amount_type: "fixed",
        default_amount: 10,
        show_in_payroll_grid: false
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: visible, amount: 95)
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: hidden, amount: 10)

      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_field_inputs"

      expect(response).to have_http_status(:ok)
      worksheet = response.parsed_body.fetch("payroll_field_inputs")
      expect(worksheet.fetch("fields").pluck("name")).to eq([ "Company Rent" ])
      expect(worksheet.fetch("assignments").first).to include(
        "employee_id" => employee.id,
        "payroll_field_definition_id" => visible.id,
        "suggested_amount" => 95.0,
        "editable" => true,
        "overridden" => false
      )
    end

    it "marks an imported direct-loan field as non-editable to prevent double deduction" do
      loan_field = PayrollFieldDefinition.create!(
        company: company,
        name: "MoSa Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount_type: "manual",
        show_in_payroll_grid: true
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: loan_field)
      pay_period.payroll_items.create!(
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15,
        loan_deduction: 50,
        import_source: "mosa_revel"
      )

      get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_field_inputs"

      assignment = response.parsed_body.dig("payroll_field_inputs", "assignments", 0)
      expect(assignment).to include("editable" => false)
      expect(assignment.fetch("skipped_reason")).to match(/already supplied/i)
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

  describe "POST /api/v1/admin/pay_periods/:id/unapprove" do
    it "returns an approved pay period to calculated with an audit timestamp" do
      pay_period.update!(status: "approved", approved_by_id: admin_user.id, approved_at: 1.hour.ago)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/unapprove"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload).to have_attributes(
        status: "calculated",
        approved_by_id: nil,
        approved_at: nil,
        unapproved_by_id: admin_user.id
      )
      expect(pay_period.unapproved_at).to be_present
    end

    it "cannot unapprove a committed pay period" do
      pay_period.update!(status: "committed", committed_at: Time.current, committed_by_id: admin_user.id)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/unapprove"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Can only unapprove an approved pay period")
      expect(pay_period.reload.status).to eq("committed")
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

      item = pay_period.payroll_items.first
      assigned_event = item.check_events.find_by(event_type: "assigned")
      expect(assigned_event).to be_present
      expect(assigned_event.check_number).to eq(item.reload.check_number)
      expect(assigned_event.reason).to eq("Assigned when pay period was committed")
    end

    it "atomically records immutable payroll liabilities from stored item values" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      posting = pay_period.payroll_liability_postings.find_by!(posting_type: "commit")
      expect(posting.entries.sum(:amount)).to eq(191.80)
      expect(posting.entries.pluck(:component_key, :amount).to_h).to include(
        "guam_income_tax_withheld" => 100.00,
        "social_security_employee" => 74.40,
        "medicare_employee" => 17.40
      )
    end

    it "includes W-4 Step 4(c) extra withholding in the automatic Guam FIT deposit check" do
      company.update!(auto_create_fit_check: true)
      pay_period.payroll_items.first.update!(additional_withholding: 25)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      fit_check = pay_period.non_employee_checks.find_by!(auto_generated_type: "fit_deposit")
      expect(fit_check.amount).to eq(125.00)
    end

    it "rolls back the payroll commit when liability posting fails" do
      allow(PayrollLiabilityPostingService).to receive(:post!)
        .and_raise(PayrollLiabilityPostingService::InvalidStateError, "posting rejected")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("posting rejected")
      expect(pay_period.reload.status).to eq("approved")
      expect(EmployeeYtdTotal.find_by(employee: employee, year: pay_period.pay_date.year)).to be_nil
      expect(CompanyYtdTotal.find_by(company: company, year: pay_period.pay_date.year)).to be_nil
      expect(pay_period.payroll_liability_postings).to be_empty
    end

    it "skips previously issued intermediate check numbers when committing from a lower sequence" do
      company.update!(next_check_number: 999)
      prior_period = PayPeriod.create!(
        company: company,
        start_date: pay_period.start_date - 14.days,
        end_date: pay_period.end_date - 14.days,
        pay_date: pay_period.pay_date - 14.days,
        status: "committed",
        committed_at: Time.current
      )
      create(:payroll_item, :with_check,
        pay_period: prior_period,
        employee: employee,
        check_number: "1000")
      second_employee = create(:employee, company: company, department: department)
      create(:payroll_item,
        pay_period: pay_period,
        employee: second_employee,
        gross_pay: 1000.00,
        net_pay: 840.00,
        withholding_tax: 80.00,
        social_security_tax: 62.00,
        medicare_tax: 14.50)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      assigned_numbers = pay_period.payroll_items.not_voided.pluck(:check_number).sort_by(&:to_i)
      expect(assigned_numbers).to eq(%w[999 1001])
      expect(company.reload.next_check_number).to eq(1002)
    end

    it "does not enqueue tax sync when the CST ingest integration is not configured" do
      allow(PayrollTaxSyncJob).to receive(:perform_later)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.tax_sync_status).to be_nil
      expect(response.parsed_body.dig("pay_period", "tax_sync_status")).to be_nil
      expect(response.parsed_body.dig("pay_period", "lifecycle")).not_to have_key("tax_synced")
      expect(PayrollTaxSyncJob).not_to have_received(:perform_later)
    end

    it "registers tax sync enqueue on transaction commit when CST ingest is configured" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CST_INGEST_URL").and_return("https://tax.example.test/ingest")
      allow(PayrollTaxSyncJob).to receive(:perform_later)
      allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:ok)
      expect(pay_period.reload.tax_sync_status).to eq("pending")
      expect(ActiveRecord).to have_received(:after_all_transactions_commit)
      expect(PayrollTaxSyncJob).to have_received(:perform_later).with(pay_period.id)
    end

    it "cannot commit when no payroll items exist" do
      pay_period.payroll_items.destroy_all

      post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("no payroll items")
    end

    it "returns not configured instead of failing when retrying disabled tax sync" do
      pay_period.update!(
        status: "committed",
        committed_at: Time.current,
        tax_sync_status: "failed",
        tax_sync_attempts: 1,
        tax_sync_last_error: "CST_INGEST_URL is not configured",
        tax_sync_idempotency_key: "cpr-stale-sync"
      )
      allow(PayrollTaxSyncJob).to receive(:perform_later)

      post "/api/v1/admin/pay_periods/#{pay_period.id}/retry_tax_sync"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Tax sync is not configured")
      expect(pay_period.reload).to have_attributes(
        tax_sync_status: nil,
        tax_sync_attempts: 0,
        tax_sync_last_error: nil,
        tax_sync_idempotency_key: nil
      )
      expect(PayrollTaxSyncJob).not_to have_received(:perform_later)
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
