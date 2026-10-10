# frozen_string_literal: true

require "json"
require "fileutils"

# Disposable fixture for the real-stack payroll refresh acceptance journey.
# It never runs through an HTTP endpoint and refuses non-test/populated data.
class PayrollRefreshQaFixture
  def self.seed!(output_path:)
    raise "Synthetic QA requires Rails test and E2E_TEST_MODE=true" unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true"
    raise "Synthetic QA requires an empty application database" if Company.exists? || User.exists? || Employee.exists?

    require "factory_bot"
    FactoryBot.find_definitions if FactoryBot.factories.none?
    load Rails.root.join("db/seeds/tax_configs.rb") unless AnnualTaxConfig.for_year(2026)&.config_for("single")

    fixture = ApplicationRecord.transaction do
      company = FactoryBot.create(:company, name: "Synthetic Payroll Refresh QA",
        pay_frequency: "semimonthly", auto_create_fit_check: true)
      actor = User.create!(company: company, organization: company.organization,
        email: "refresh-accountant@example.test", name: "QA Accountant", role: "accountant", active: true)
      company.organization.update!(primary_company: company)
      CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0,
        timezone: "Pacific/Guam", effective_on: Date.new(2026, 1, 1), source: "operator_confirmed",
        confirmation_status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
        notes: "Synthetic QA confirmed workweek")
      department = Department.create!(company: company, name: "Synthetic Operations")
      build_employee = lambda do |name|
        FactoryBot.create(:employee, company: company, department: department,
          first_name: "QA", last_name: name, pay_rate: 16, pay_frequency: "semimonthly",
          hire_date: Date.new(2026, 1, 1), payment_delivery_method: "paper_check")
      end
      build_loan = lambda do |employee|
        type = DeductionType.create!(company: company, name: "#{employee.full_name} Loan",
          category: "post_tax", sub_category: "loan", active: true)
        loan = EmployeeLoan.create!(company: company, employee: employee, deduction_type: type,
          name: "#{employee.full_name} Loan", tracking_mode: "balance_tracked",
          original_amount: 3259.97, current_balance: 3259.97, opening_balance: 3259.97,
          balance_as_of: Date.new(2026, 10, 10), balance_source: "other_verified",
          payment_amount: 300, first_deduction_date: Date.new(2026, 10, 10),
          status: "active", created_by: actor)
        EmployeeDeduction.create!(employee: employee, deduction_type: type, amount: 300, active: true)
        loan
      end
      build_period = lambda do |employee, status|
        period = FactoryBot.create(:pay_period, company: company,
          start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 15), pay_date: Date.new(2026, 10, 10),
          run_purpose: "adjustment", includes_base_salary: false, includes_recurring_items: false)
        item = FactoryBot.create(:payroll_item, company: company, employee: employee, pay_period: period,
          pay_rate: 16, hours_worked: 80.3, overtime_hours: 14)
        if status != "draft"
          item.calculate!
          item.save!
          period.update!(status: "calculated")
          PayPeriodLifecycleService.new(pay_period: period, actor: actor).approve! if %w[approved committed delivered].include?(status)
          PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit! if %w[committed delivered].include?(status)
          if status == "delivered"
            item.reload.mark_printed!(user: actor)
            item.mark_delivered!(user: actor, delivered_on: Date.new(2026, 10, 10),
              delivery_method: "hand_delivery", attestation: true, note: "Synthetic local QA delivery")
          end
        end
        [ period, item ]
      end

      desktop_employee = build_employee.call("Desktop")
      desktop_loan = build_loan.call(desktop_employee)
      desktop_period, desktop_item = build_period.call(desktop_employee, "draft")
      mobile_employee = build_employee.call("Mobile")
      mobile_loan = build_loan.call(mobile_employee)
      mobile_period, mobile_item = build_period.call(mobile_employee, "draft")
      reopen_employee = build_employee.call("Reopen")
      reopen_period, reopen_item = build_period.call(reopen_employee, "committed")
      reopen_loan = build_loan.call(reopen_employee)
      reopen_employee.update!(pay_rate: 18)
      refresh_employee = build_employee.call("Refresh Approved")
      refresh_period, refresh_item = build_period.call(refresh_employee, "approved")
      refresh_loan = build_loan.call(refresh_employee)
      refresh_employee.update!(pay_rate: 18)
      delivered_employee = build_employee.call("Delivered Block")
      delivered_period, delivered_item = build_period.call(delivered_employee, "delivered")
      multirate_employee = build_employee.call("Multi Rate")
      primary = multirate_employee.employee_wage_rates.create!(label: "Primary", rate: 12, is_primary: true)
      secondary = multirate_employee.employee_wage_rates.create!(label: "Secondary", rate: 20)
      multirate_period, multirate_item = build_period.call(multirate_employee, "draft")
      multirate_item.update!(hours_worked: 80, overtime_hours: 0, pay_rate: 12, wage_rate_hours: [
        { "employee_wage_rate_id" => primary.id, "label" => "Primary", "rate" => 12, "regular_hours" => 40, "is_primary" => true },
        { "employee_wage_rate_id" => secondary.id, "label" => "Secondary", "rate" => 20, "regular_hours" => 40 }
      ])
      multirate_item.calculate!
      multirate_item.save!
      multirate_period.update!(status: "calculated")
      multirate_lifecycle = PayPeriodLifecycleService.new(pay_period: multirate_period, actor: actor)
      multirate_lifecycle.approve!
      multirate_lifecycle.commit!
      multirate_loan = build_loan.call(multirate_employee)
      primary.update!(rate: 16)
      secondary.update!(rate: 30, active: false)
      unavailable_employee = build_employee.call("Unavailable Loan")
      unavailable_loan = build_loan.call(unavailable_employee)
      unavailable_period, unavailable_item = build_period.call(unavailable_employee, "draft")
      unavailable_item.update!(named_loan_payments: { unavailable_loan.id.to_s => "300.00" })
      unavailable_loan.update!(status: "suspended")
      companion = build_employee.call("Unselected Bonus")
      companion.update!(default_payroll_adjustments: [
        { "label" => "Synthetic recurring bonus", "amount" => 100, "treatment" => "taxable_addition", "active" => true }
      ])
      {
        schema_version: 1, company_id: company.id, accountant_email: actor.email,
        desktop: { period_id: desktop_period.id, item_id: desktop_item.id, employee_id: desktop_employee.id, loan_id: desktop_loan.id },
        mobile: { period_id: mobile_period.id, item_id: mobile_item.id, employee_id: mobile_employee.id, loan_id: mobile_loan.id },
        reopen: { period_id: reopen_period.id, item_id: reopen_item.id, employee_id: reopen_employee.id, loan_id: reopen_loan.id },
        approved_refresh: { period_id: refresh_period.id, item_id: refresh_item.id, employee_id: refresh_employee.id, loan_id: refresh_loan.id },
        delivered: { period_id: delivered_period.id, item_id: delivered_item.id, employee_id: delivered_employee.id },
        multirate: { period_id: multirate_period.id, item_id: multirate_item.id, employee_id: multirate_employee.id, loan_id: multirate_loan.id },
        unavailable: { period_id: unavailable_period.id, item_id: unavailable_item.id, employee_id: unavailable_employee.id, loan_id: unavailable_loan.id },
        unselected_employee_id: companion.id
      }
    end
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, JSON.pretty_generate(fixture))
    fixture
  end
end
