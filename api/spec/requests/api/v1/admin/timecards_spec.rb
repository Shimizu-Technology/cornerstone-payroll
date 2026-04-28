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
    end
  end
end
