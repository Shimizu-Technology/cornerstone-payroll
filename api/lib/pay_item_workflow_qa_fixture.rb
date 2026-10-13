# frozen_string_literal: true

require "json"
require "fileutils"

# Synthetic client shapes for the pay-item release lane. No production records
# are copied, and this is deliberately unavailable through an HTTP endpoint.
class PayItemWorkflowQaFixture
  def self.seed!(output_path:)
    raise "Pay-item QA requires Rails test and E2E_TEST_MODE=true" unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true"
    raise "Pay-item QA requires an empty application database" if Organization.exists? || Company.exists? || User.exists? || Employee.exists?

    require "factory_bot"
    FactoryBot.find_definitions if FactoryBot.factories.none?
    load Rails.root.join("db/seeds/tax_configs.rb") unless AnnualTaxConfig.for_year(2026)&.config_for("single")

    fixture = ApplicationRecord.transaction { new.build }
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, JSON.pretty_generate(fixture))
    fixture
  end

  def build
    organization = Organization.create!(name: "Synthetic Pay-item Firm", slug: "pay-item-qa", status: "active")
    aire = FactoryBot.create(:company, organization: organization, name: "Synthetic Aviation QA", pay_frequency: "semimonthly", auto_create_fit_check: false)
    mosa = FactoryBot.create(:company, organization: organization, name: "Synthetic Hospitality QA", pay_frequency: "semimonthly", auto_create_fit_check: false)
    organization.update!(primary_company: aire)
    admin = User.create!(organization: organization, company: aire, name: "QA Admin", email: "pay-items-admin@example.test", role: "org_admin", active: true)
    accountant = User.create!(organization: organization, company: aire, name: "QA Accountant", email: "pay-items-accountant@example.test", role: "accountant", active: true)
    [ aire, mosa ].each do |company|
      CompanyAssignment.create!(user: accountant, company: company)
      CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0,
        timezone: "Pacific/Guam", effective_on: Date.new(2026, 1, 1), source: "operator_confirmed",
        confirmation_status: "confirmed", confirmed_by: admin, confirmed_at: Time.current,
        notes: "Synthetic QA confirmed workweek")
    end

    recipient = employee(aire, "Allowance Recipient", contractor: true)
    coworker = employee(aire, "Unassigned Coworker", contractor: true)
    admin_recipient = employee(aire, "Admin Recipient", contractor: true)
    chief = employee(aire, "Legacy Chief")
    chief.update!(default_payroll_adjustments: [ { "label" => "Chief Pilot", "amount" => 750, "treatment" => "taxable_addition", "active" => true } ])
    inherited = employee(mosa, "Inherited Default")
    explicit_zero = employee(mosa, "Zero Override")
    private_owner = employee(mosa, "Private Owner")
    fixed = field(mosa, "Shared fixed allowance", default_amount: 125)
    percentage = field(mosa, "Shared percentage deduction", kind: "deduction", tax_treatment: "post_tax_deduction", amount_type: "percentage", default_percentage: 2, default_amount: nil)
    manual = field(mosa, "Shared manual addition", amount_type: "manual", default_amount: 10)
    contribution = field(mosa, "Shared employer benefit", kind: "employer_contribution", tax_treatment: "employer_contribution", default_amount: 50, category: "benefit")
    private_field = field(mosa, "Private allowance", owner_employee: private_owner, default_amount: nil, reporting_group: "401k_pre_tax")
    paused = field(mosa, "Paused allowance", default_amount: 400)
    ended = field(mosa, "Ended allowance", default_amount: 500)
    assignments = {
      inherited: assign(inherited, fixed, amount: nil),
      zero: assign(explicit_zero, fixed, amount: 0),
      personal: assign(private_owner, private_field, amount: 80),
      percentage: assign(inherited, percentage, percentage: nil),
      manual: assign(inherited, manual, amount: 35),
      contribution: assign(inherited, contribution, amount: nil),
      paused: assign(inherited, paused, active: false),
      ended: assign(inherited, ended, end_date: Date.new(2026, 9, 30))
    }
    loan_type = DeductionType.create!(company: mosa, name: "Tracked QA Loan", category: "post_tax", sub_category: "loan", active: true)
    loan = EmployeeLoan.create!(company: mosa, employee: inherited, deduction_type: loan_type,
      name: "Tracked QA Loan", tracking_mode: "balance_tracked", original_amount: 1000,
      current_balance: 1000, opening_balance: 1000, balance_as_of: Date.new(2026, 10, 1),
      balance_source: "other_verified", payment_amount: 100, first_deduction_date: Date.new(2026, 10, 1), status: "active", created_by: admin)
    EmployeeDeduction.create!(employee: inherited, deduction_type: loan_type, amount: 100, active: true)
    standalone = field(mosa, "Standalone QA deduction", kind: "deduction", tax_treatment: "post_tax_deduction", default_amount: 40)
    assign(inherited, standalone, amount: 40)

    history = period(mosa, [ inherited, explicit_zero, private_owner ], pay_date: Date.new(2026, 9, 15), committed: true, actor: admin)
    chief_history = period(aire, [ chief ], pay_date: Date.new(2026, 9, 15), committed: true, actor: admin)
    regular = period(aire, [ recipient, coworker, chief ], pay_date: Date.new(2026, 10, 15))
    before_start = period(aire, [ recipient ], pay_date: Date.new(2026, 10, 12))
    special = period(aire, [ recipient ], pay_date: Date.new(2026, 10, 16), recurring: false)
    hospitality = period(mosa, [ inherited, explicit_zero, private_owner ], pay_date: Date.new(2026, 10, 15))
    admin_regular = period(aire, [ admin_recipient ], pay_date: Date.new(2026, 10, 15))
    {
      schema_version: 1, accountant_email: accountant.email, admin_email: admin.email,
      companies: { aire: aire.id, mosa: mosa.id },
      employees: { recipient: recipient.id, coworker: coworker.id, admin_recipient: admin_recipient.id,
        chief: chief.id, inherited: inherited.id, zero: explicit_zero.id, private_owner: private_owner.id },
      fields: { fixed: fixed.id, percentage: percentage.id, manual: manual.id, contribution: contribution.id,
        personal: private_field.id, paused: paused.id, ended: ended.id, standalone: standalone.id },
      assignments: assignments.transform_values(&:id), loan_id: loan.id,
      periods: { history: history.id, chief_history: chief_history.id, regular: regular.id,
        before_start: before_start.id, special: special.id, hospitality: hospitality.id, admin_regular: admin_regular.id }
    }
  end

  private

  def employee(company, name, contractor: false)
    department = company.departments.first || Department.create!(company: company, name: "Synthetic Operations")
    FactoryBot.create(:employee, *(contractor ? [ :contractor ] : []), company: company, department: department,
      first_name: "QA", last_name: name, pay_rate: contractor ? 1000 : 15, pay_frequency: "semimonthly",
      hire_date: Date.new(2026, 1, 1), payment_delivery_method: "paper_check")
  end

  def field(company, name, **attrs)
    PayrollFieldDefinition.create!({ company: company, name: name, kind: "addition",
      tax_treatment: "taxable_addition", category: "other", amount_type: "fixed",
      default_amount: 0, active: true, show_in_payroll_grid: true }.merge(attrs))
  end

  def assign(employee, field, **attrs)
    employee.employee_payroll_fields.create!({ payroll_field_definition: field, active: true }.merge(attrs))
  end

  def period(company, employees, pay_date:, recurring: true, committed: false, actor: nil)
    start_date = pay_date - 20
    period = FactoryBot.create(:pay_period, company: company, start_date: start_date,
      end_date: start_date + 14, pay_date: pay_date, run_purpose: recurring ? "regular" : "adjustment",
      includes_base_salary: true, includes_recurring_items: recurring)
    employees.each do |employee|
      item = FactoryBot.create(:payroll_item, company: company, employee: employee, pay_period: period,
        employment_type: employee.employment_type, pay_rate: employee.pay_rate, hours_worked: employee.contractor? ? 0 : 80)
      next unless committed

      item.sync_default_payroll_adjustments!(employee)
      item.calculate!
      item.save!
    end
    if committed
      period.update!(status: "calculated")
      lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
    end
    period
  end
end
