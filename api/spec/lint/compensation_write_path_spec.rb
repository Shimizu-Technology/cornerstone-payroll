# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/compensation_write_lint")

# CI static check for the M3-4 single write path (also `bin/rails compensation:lint_writes`).
RSpec.describe CompensationWriteLint do
  it "finds no raw pay-rate or compensation-history writes outside the service" do
    offenses = described_class.offenses
    expect(offenses).to be_empty, "Pay rates change only through EmployeeCompensationChangeService:\n#{offenses.map(&:to_s).join("\n")}"
  end

  {
    "attrs = ({ pay_rate: BigDecimal('12') }); employee.update_columns((attrs))" => "bulk or callback-skipping write naming pay_rate",
    "row = EmployeeWageRate.find(5); row.delete" => "bulk or callback-skipping write on employee wage rates",
    "employee.employee_wage_rates\n  .where(active: true)\n  .update_all(rate: 30)" => "bulk or callback-skipping write on employee wage rates",
    "employee.update_columns(pay_frequency: 'monthly')" => "bulk or callback-skipping write on employee compensation",
    %q(execute('INSERT INTO "public"."employee_wage_rates" DEFAULT VALUES')) => "raw SQL write on pay rates or compensation history",
    %q(execute('TRUNCATE TABLE "public"."employee_compensation_changes"')) => "raw SQL write on pay rates or compensation history",
    %q(execute('DELETE FROM public.employee_wage_rates')) => "raw SQL write on pay rates or compensation history",
    "employee.update_columns(pay_rate: 20)" => "bulk or callback-skipping write naming pay_rate",
    "Employee.where(company_id: 1).update_all(pay_rate: 0, updated_at: Time.current)" => "bulk or callback-skipping write naming pay_rate",
    "employee.update_column(:pay_rate, 20)" => "bulk or callback-skipping write naming pay_rate",
    "Employee.upsert_all([{ id: 1, pay_rate: 9 }])" => "bulk or callback-skipping write naming pay_rate",
    "employee.employee_wage_rates.update_all(rate: 30)" => "bulk or callback-skipping write on employee wage rates",
    "EmployeeWageRate.where(employee_id: 1).delete_all" => "bulk or callback-skipping write on employee wage rates",
    "EmployeeCompensationChange.where(employee_id: 1).delete_all" => "bulk write on compensation history",
    %(execute("UPDATE employees SET pay_rate = 0")) => "raw SQL write on pay rates or compensation history",
    %(execute("UPDATE employee_wage_rates SET rate = 0")) => "raw SQL write on pay rates or compensation history",
    %(execute("DELETE FROM employee_wage_rate_versions")) => "raw SQL write on pay rates or compensation history"
  }.each do |source, rule|
    it "flags #{source}" do
      expect(described_class.scan("#{source}\n", "app/example.rb").map(&:rule)).to include(rule)
    end
  end

  it "flags a multi-line update_columns call" do
    source = "employee.update_columns(\n  first_name: \"A\",\n  pay_rate: 20\n)\n"
    expect(described_class.scan(source, "app/example.rb").map(&:line)).to eq([ 1 ])
  end

  it "ignores comments and unrelated bulk writes" do
    source = <<~RUBY
      # employee.update_columns(pay_rate: 20) is not allowed
      payroll_item.update_columns(gross_pay: 10)
      Employee.where(id: 1).update_all(intake_payroll_confirmed_at: nil)
    RUBY
    expect(described_class.scan(source, "app/example.rb")).to be_empty
  end
end
