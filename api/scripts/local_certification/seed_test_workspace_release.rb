# frozen_string_literal: true

database_name = ActiveRecord::Base.connection_db_config.database.to_s
unless ENV["E2E_TEST_MODE"] == "true" && database_name.start_with?("cornerstone_artifacts_training_e2e_")
  abort "Refusing to seed outside an isolated test-workspace release database"
end

populated = {
  organizations: Organization.count,
  companies: Company.count,
  users: User.count,
  employees: Employee.count,
  pay_periods: PayPeriod.count
}.reject { |_name, count| count.zero? }
abort "Refusing to seed a populated database: #{populated.inspect}" if populated.any?

fixture = ApplicationRecord.transaction do
  organization = Organization.create!(
    name: "Local Cornerstone Certification",
    slug: "local-cornerstone-certification",
    status: "active"
  )
  company = organization.companies.create!(
    name: "Spike Coffee Roasters — Local Test",
    pay_frequency: "biweekly",
    check_stock_type: "bottom_check",
    address_line1: "100 Test Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910"
  )
  organization.update!(primary_company: company)
  admin = User.create!(
    organization: organization,
    company: company,
    email: "admin@local-certification.test",
    name: "Local Payroll Admin",
    role: "org_admin",
    active: true
  )
  accountant = User.create!(
    organization: organization,
    company: company,
    email: "accountant@local-certification.test",
    name: "Training Accountant",
    role: "accountant",
    active: true
  )
  employee = Employee.create!(
    company: company,
    first_name: "Ada",
    last_name: "Trainer",
    employment_type: "hourly",
    pay_rate: 20,
    pay_frequency: "biweekly",
    status: "active",
    hire_date: Date.new(2025, 1, 1),
    ssn_encrypted: "900-00-0001",
    filing_status: "single",
    allowances: 0,
    retirement_rate: 0,
    roth_retirement_rate: 0,
    employer_retirement_match_rate: 0,
    employer_roth_match_rate: 0,
    w4_dependent_credit: 0,
    w4_step4a_other_income: 0,
    w4_step4b_deductions: 0,
    w4_form_version: 2026,
    payment_delivery_method: "paper_check",
    address_line1: "101 Test Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910"
  )
  TaxTable.create!(
    tax_year: 2026,
    filing_status: "single",
    pay_frequency: "biweekly",
    ss_rate: 0.062,
    ss_wage_base: 184_500,
    medicare_rate: 0.0145,
    allowance_amount: 192.31,
    bracket_data: [
      { min_income: 0, max_income: 476.92, rate: 0.10, base_tax: 0, threshold: 0 },
      { min_income: 476.93, max_income: 1_938.46, rate: 0.12, base_tax: 47.69, threshold: 476.93 },
      { min_income: 1_938.47, max_income: 999_999_999, rate: 0.22, base_tax: 223.07, threshold: 1_938.47 }
    ]
  )

  period_specs = [
    [ Date.new(2026, 7, 26), Date.new(2026, 8, 8), Date.new(2026, 8, 14), "committed", "7000", 1_520 ],
    [ Date.new(2026, 8, 9), Date.new(2026, 8, 22), Date.new(2026, 8, 28), "committed", "7001", 1_600 ],
    [ Date.new(2026, 8, 23), Date.new(2026, 9, 5), Date.new(2026, 9, 11), "calculated", nil, 1_680 ]
  ]
  periods = period_specs.map do |start_date, end_date, pay_date, status, check_number, gross_pay|
    period = PayPeriod.create!(
      company: company,
      start_date: start_date,
      end_date: end_date,
      pay_date: pay_date,
      status: status,
      calculated_at: pay_date - 2.days,
      approved_at: status == "committed" ? pay_date - 1.day : nil,
      committed_at: status == "committed" ? pay_date : nil,
      calculated_by_id: admin.id,
      approved_by_id: status == "committed" ? admin.id : nil,
      committed_by_id: status == "committed" ? admin.id : nil
    )
    PayrollItem.create!(
      company: company,
      pay_period: period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: gross_pay / 20,
      gross_pay: gross_pay,
      withholding_tax: 160,
      social_security_tax: gross_pay * 0.062,
      medicare_tax: gross_pay * 0.0145,
      total_deductions: 282,
      net_pay: gross_pay - 282,
      check_number: check_number,
      check_date: check_number && pay_date,
      payment_delivery_method: "paper_check"
    )
    period
  end

  {
    company_id: company.id,
    admin_id: admin.id,
    accountant_id: accountant.id,
    printable_pay_period_id: periods.second.id,
    calculated_pay_period_id: periods.third.id
  }
end

puts fixture.to_json
