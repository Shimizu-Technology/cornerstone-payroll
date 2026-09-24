# frozen_string_literal: true

require "digest"

module MigrationPromotion
  class TargetFingerprint
    COMPANY_ASSOCIATIONS = %i[
      departments deduction_types payroll_field_definitions company_pay_schedules company_workweeks
      pay_component_tax_rules employees employee_loans company_ytd_totals pay_periods
    ].freeze
    EMPLOYEE_MODELS = [
      EmployeeDeduction,
      EmployeePayrollField,
      EmployeeWageRate,
      EmployeeW4Election,
      EmployeeWorkProfile,
      EmployeeStatusEvent,
      EmployeeTippedOccupation,
      EmployeeRetirementElection,
      EmployeeYtdTotal
    ].freeze

    def self.call(company)
      new(company).call
    end

    def initialize(company)
      @company = company
    end

    def call
      parts = [ "company:#{company.id}:#{timestamp(company.updated_at)}" ]
      COMPANY_ASSOCIATIONS.each do |association|
        parts << relation_signature(company.public_send(association))
      end
      EMPLOYEE_MODELS.each do |model|
        parts << relation_signature(model.joins(:employee).where(employees: { company_id: company.id }))
      end
      parts << relation_signature(LoanTransaction.joins(:employee_loan).where(employee_loans: { company_id: company.id }))
      parts << relation_signature(PayrollItem.where(pay_period_id: company.pay_periods.select(:id)))
      parts << relation_signature(
        PayPeriodExcludedEmployee.where(pay_period_id: company.pay_periods.select(:id))
      )
      Digest::SHA256.hexdigest(parts.join("|"))
    end

    private

    attr_reader :company

    def relation_signature(relation)
      table_name = relation.klass.quoted_table_name
      count, latest = relation.unscope(:order).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("MAX(#{table_name}.updated_at)")
      )
      "#{relation.klass.table_name}:#{count}:#{timestamp(latest)}"
    end

    def timestamp(value)
      value&.utc&.iso8601(6).to_s
    end
  end
end
