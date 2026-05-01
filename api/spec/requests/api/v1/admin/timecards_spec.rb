# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Timecards", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "timecards-admin@example.com",
      name: "Timecards Admin",
      role: "admin",
      active: true
    )
  end
  let!(:pay_period) { create(:pay_period, company: company, status: "draft") }
  let!(:employee) do
    create(:employee, company: company, first_name: "Multi", last_name: "Rate", employment_type: "hourly", pay_rate: 30)
  end
  let!(:flight_rate) do
    EmployeeWageRate.create!(employee: employee, label: "Flight Hours", rate: 30, is_primary: true, active: true)
  end
  let!(:admin_rate) do
    EmployeeWageRate.create!(employee: employee, label: "Admin Duties", rate: 10, is_primary: false, active: true)
  end
  let!(:legacy_rate) do
    EmployeeWageRate.create!(employee: employee, label: "Legacy Training", rate: 20, is_primary: false, active: false)
  end
  let!(:timecard) do
    Timecard.create!(
      company: company,
      pay_period: pay_period,
      employee_name: employee.full_name,
      ocr_status: "reviewed",
      reviewed_by_name: "Admin",
      reviewed_at: Time.current,
      period_start: pay_period.start_date,
      period_end: pay_period.end_date
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::TimecardsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::TimecardsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(PayrollItem).to receive(:calculate!) do |item|
      item.save!
    end

    PunchEntry.create!(
      timecard: timecard,
      card_day: 1,
      date: pay_period.start_date,
      clock_in: "08:00",
      clock_out: "13:00",
      confidence: 0.95,
      review_state: "approved",
      reviewed_by_name: "Admin"
    )
  end

  describe "POST /api/v1/admin/timecards/:id/apply_to_payroll" do
    it "requires a wage-rate choice for multi-rate employees" do
      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Choose which earning type")
    end

    it "applies OCR hours to the selected wage rate without removing other rates" do
      item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company, employment_type: "hourly")
      item.wage_rate_hours = [
        { employee_wage_rate_id: flight_rate.id, label: "Flight Hours", rate: 30, regular_hours: 2, overtime_hours: 0, active: true, is_primary: true },
        { employee_wage_rate_id: admin_rate.id, label: "Admin Duties", rate: 10, regular_hours: 3, overtime_hours: 0, active: true, is_primary: false }
      ]
      item.save!

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id, wage_rate_id: flight_rate.id }

      expect(response).to have_http_status(:ok)
      wage_rates = item.reload.wage_rate_hours
      expect(wage_rates.map { |rate| rate["label"] }).to contain_exactly("Flight Hours", "Admin Duties")
      expect(wage_rates.find { |rate| rate["label"] == "Flight Hours" }["regular_hours"]).to eq(5.0)
      expect(wage_rates.find { |rate| rate["label"] == "Admin Duties" }["regular_hours"]).to eq(3.0)
      expect(response.parsed_body.dig("payroll_item", "state_withheld")).to be_nil
    end

    it "applies recalculated punch-pair hours instead of stale stored hours" do
      timecard.punch_entries.destroy_all
      stale_entry = PunchEntry.create!(
        timecard: timecard,
        card_day: 26,
        date: Date.new(2026, 4, 26),
        clock_in: "08:25",
        lunch_out: "12:02",
        confidence: 0.95,
        review_state: "approved",
        reviewed_by_name: "Admin"
      )
      stale_entry.update_column(:hours_worked, 10.77)

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id, wage_rate_id: flight_rate.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("payroll_item", "wage_rate_hours").find { |rate| rate["label"] == "Flight Hours" }["regular_hours"]).to eq(3.62)
      expect(response.parsed_body.dig("timecard", "punch_entries").first["hours_worked"]).to eq(3.62)
    end

    it "preserves hours from inactive wage rates when re-applying OCR hours" do
      item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company, employment_type: "hourly")
      item.wage_rate_hours = [
        { employee_wage_rate_id: flight_rate.id, label: "Flight Hours", rate: 30, regular_hours: 2, overtime_hours: 0, active: true, is_primary: true },
        { employee_wage_rate_id: admin_rate.id, label: "Admin Duties", rate: 10, regular_hours: 3, overtime_hours: 0, active: true, is_primary: false },
        { employee_wage_rate_id: legacy_rate.id, label: "Legacy Training", rate: 20, regular_hours: 4, overtime_hours: 0, active: false, is_primary: false }
      ]
      item.save!

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id, wage_rate_id: admin_rate.id }

      expect(response).to have_http_status(:ok)
      wage_rates = item.reload.wage_rate_hours
      expect(wage_rates.map { |rate| rate["label"] }).to contain_exactly("Flight Hours", "Admin Duties", "Legacy Training")
      expect(wage_rates.find { |rate| rate["label"] == "Admin Duties" }["regular_hours"]).to eq(5.0)
      expect(wage_rates.find { |rate| rate["label"] == "Flight Hours" }["regular_hours"]).to eq(2.0)
      expect(wage_rates.find { |rate| rate["label"] == "Legacy Training" }["regular_hours"]).to eq(4.0)
      expect(item.reload.hours_worked).to eq(11.0)
    end

    it "clears stale non-regular hours from the selected wage rate when re-applying OCR hours" do
      item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company, employment_type: "hourly")
      item.wage_rate_hours = [
        { employee_wage_rate_id: flight_rate.id, label: "Flight Hours", rate: 30, regular_hours: 40, overtime_hours: 5, holiday_hours: 2, pto_hours: 1, active: true, is_primary: true },
        { employee_wage_rate_id: admin_rate.id, label: "Admin Duties", rate: 10, regular_hours: 3, overtime_hours: 4, holiday_hours: 0, pto_hours: 0, active: true, is_primary: false }
      ]
      item.save!

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id, wage_rate_id: flight_rate.id }

      expect(response).to have_http_status(:ok)
      wage_rates = item.reload.wage_rate_hours
      flight_entry = wage_rates.find { |rate| rate["label"] == "Flight Hours" }
      admin_entry = wage_rates.find { |rate| rate["label"] == "Admin Duties" }

      expect(flight_entry["regular_hours"]).to eq(5.0)
      expect(flight_entry["overtime_hours"]).to eq(0.0)
      expect(flight_entry["holiday_hours"]).to eq(0.0)
      expect(flight_entry["pto_hours"]).to eq(0.0)
      expect(admin_entry["overtime_hours"]).to eq(4.0)
      expect(item.hours_worked).to eq(8.0)
      expect(item.overtime_hours).to eq(4.0)
      expect(item.holiday_hours).to eq(0.0)
      expect(item.pto_hours).to eq(0.0)
    end

    it "does not double-count wage-rate hours when entries contain string and symbol keys" do
      controller = Api::V1::Admin::TimecardsController.new

      hours = controller.send(
        :entry_hours,
        { regular_hours: 5, "regular_hours" => 5 },
        :regular_hours
      )

      expect(hours).to eq(5.0)
    end

    it "serializes payroll items without department fields when the employee is missing" do
      item = build_stubbed(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      allow(item).to receive(:employee).and_return(nil)
      allow(item).to receive(:employee_full_name).and_return("Deleted Employee")
      controller = Api::V1::Admin::TimecardsController.new

      payload = controller.send(:payroll_item_json, item)

      expect(payload[:department_id]).to be_nil
      expect(payload[:department_name]).to be_nil
    end

    it "returns a friendly error when payroll calculation fails" do
      allow_any_instance_of(PayrollItem).to receive(:calculate!).and_raise(StandardError, "calculation exploded")

      post "/api/v1/admin/timecards/#{timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: employee.id, wage_rate_id: flight_rate.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Failed to apply timecard to payroll")
      expect(timecard.reload.applied_payroll_item_id).to be_nil
      expect(timecard.applied_to_payroll_at).to be_nil
    end

    it "resets non-regular hour fields when applying OCR hours to a single-rate employee" do
      single_rate_employee = create(:employee, company: company, first_name: "Single", last_name: "Rate", employment_type: "hourly", pay_rate: 22)
      single_rate_timecard = Timecard.create!(
        company: company,
        pay_period: pay_period,
        employee_name: single_rate_employee.full_name,
        ocr_status: "reviewed",
        reviewed_by_name: "Admin",
        reviewed_at: Time.current,
        period_start: pay_period.start_date,
        period_end: pay_period.end_date
      )
      PunchEntry.create!(
        timecard: single_rate_timecard,
        card_day: 1,
        date: pay_period.start_date,
        clock_in: "08:00",
        clock_out: "13:00",
        confidence: 0.95,
        review_state: "approved",
        reviewed_by_name: "Admin"
      )
      item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: single_rate_employee,
        company: company,
        employment_type: "hourly",
        hours_worked: 1,
        overtime_hours: 2,
        holiday_hours: 3,
        pto_hours: 4
      )

      post "/api/v1/admin/timecards/#{single_rate_timecard.id}/apply_to_payroll",
        params: { pay_period_id: pay_period.id, employee_id: single_rate_employee.id }

      expect(response).to have_http_status(:ok)
      expect(item.reload.hours_worked).to eq(5.0)
      expect(item.overtime_hours).to eq(0)
      expect(item.holiday_hours).to eq(0)
      expect(item.pto_hours).to eq(0)
    end
  end
end
