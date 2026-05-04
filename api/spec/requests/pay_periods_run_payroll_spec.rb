require "rails_helper"

RSpec.describe "PayPeriods run_payroll", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "payroll-run-spec@example.com",
      name: "Payroll Spec Admin",
      role: :admin,
      invitation_status: "accepted"
    )
  end
  let!(:employee) do
    create(
      :employee,
      company: company,
      employment_type: "hourly",
      pay_rate: 10.00
    )
  end
  let!(:pay_period) { create(:pay_period, :calculated, company: company) }

  describe "POST /api/v1/admin/pay_periods/:id/run_payroll" do
    before do
      allow_any_instance_of(PayrollItem).to receive(:calculate!) do |item|
        item.save!
      end
    end

    it "refreshes an existing single-rate payroll item from the employee pay rate" do
      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        pay_rate: 9.98,
        employment_type: "hourly",
        hours_worked: 10
      )
      payroll_item.wage_rate_hours = [
        {
          label: "Regular",
          rate: 9.98,
          regular_hours: 10,
          overtime_hours: 0,
          is_primary: true,
          active: true
        }
      ]
      payroll_item.save!

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll",
           params: {
             hours: {
               employee.id.to_s => {
                 regular: 10,
                 overtime: 0
               }
             }
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      refreshed_item = pay_period.payroll_items.find_by(employee_id: employee.id)&.reload
      expect(refreshed_item&.pay_rate.to_f).to eq(10.0)
      expect(refreshed_item&.wage_rate_hours).to eq([])
    end

    it "refreshes wage-rate entries from the employee wage rates on rerun" do
      primary_rate = EmployeeWageRate.create!(
        employee: employee,
        label: "Regular",
        rate: 10.00,
        is_primary: true,
        active: true
      )

      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        pay_rate: 9.98,
        employment_type: "hourly",
        hours_worked: 8
      )
      payroll_item.wage_rate_hours = [
        {
          employee_wage_rate_id: primary_rate.id,
          label: "Regular",
          rate: 9.98,
          regular_hours: 8,
          overtime_hours: 0,
          is_primary: true,
          active: true
        }
      ]
      payroll_item.save!

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll",
           params: {
             hours: {
               employee.id.to_s => {
                 regular: 8,
                 overtime: 0,
                 wage_rates: [
                   {
                     employee_wage_rate_id: primary_rate.id,
                     label: "Regular",
                     rate: 10.00,
                     regular_hours: 8,
                     overtime_hours: 0,
                     holiday_hours: 0,
                     pto_hours: 0,
                     is_primary: true,
                     active: true
                   }
                 ]
               }
             }
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      refreshed_item = pay_period.payroll_items.find_by(employee_id: employee.id)&.reload
      expect(refreshed_item&.pay_rate.to_f).to eq(10.0)
      expect(refreshed_item&.wage_rate_hours&.first&.dig("rate")).to eq(10.0)
    end

    it "includes submitted hourly employees when imported payroll items already exist" do
      allow_any_instance_of(PayrollItem).to receive(:calculate!) do |item|
        custom_total = Array(item.custom_earnings).sum { |earning| earning["amount"].to_f }
        item.gross_pay = (item.hours_worked.to_f * item.pay_rate.to_f) + custom_total
        item.save!
      end

      imported_employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 20.00)
      create(
        :payroll_item,
        pay_period: pay_period,
        employee: imported_employee,
        company: company,
        import_source: "manual_import",
        employment_type: "hourly",
        hours_worked: 8
      )

      employee.update!(
        default_custom_earnings: [
          { "label" => "Training Stipend", "amount" => 25.0 }
        ]
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll",
           params: {
             hours: {
               employee.id.to_s => {
                 regular: 6,
                 overtime: 0
               }
             },
             custom_earnings: {
               employee.id.to_s => [
                 { label: "Training Stipend", amount: "Infinity" },
                 { label: "Safe Bonus", amount: "12.345" }
               ]
             },
             custom_deductions: {
               employee.id.to_s => [
                 { label: "Cash Advance", amount: "Infinity" },
                 { label: "Uniform Repayment", amount: "5.555" }
               ]
             }
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      submitted_item = pay_period.payroll_items.find_by(employee_id: employee.id)&.reload
      expect(submitted_item).to be_present
      expect(submitted_item.hours_worked.to_f).to eq(6.0)
      expect(submitted_item.custom_earnings).to eq([
        { "label" => "Safe Bonus", "amount" => 12.35 }
      ])
      expect(submitted_item.custom_deductions).to eq([
        { "label" => "Uniform Repayment", "amount" => 5.56 }
      ])
      expect(submitted_item.gross_pay.to_f).to eq(72.35)
    end

    it "serializes payroll items without department fields when the employee is missing" do
      item = build_stubbed(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      allow(item).to receive(:employee).and_return(nil)
      allow(item).to receive(:employee_full_name).and_return("Deleted Employee")
      controller = Api::V1::Admin::PayPeriodsController.new

      payload = controller.send(:payroll_item_json, item)

      expect(payload[:department_id]).to be_nil
      expect(payload[:department_name]).to be_nil
    end
  end
end
