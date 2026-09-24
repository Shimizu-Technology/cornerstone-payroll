# frozen_string_literal: true

require "digest"

module TrainingReplay
  class BenchmarkSnapshot
    ITEM_FIELDS = %w[
      gross_pay net_pay withholding_tax social_security_tax medicare_tax total_deductions
      reported_tips tips_paid_out loan_deduction loan_payment hours_worked salary_override
      employment_type
    ].freeze

    def self.capture!(company:, pay_period:, source_pay_period:, actor:)
      source_items = source_pay_period.payroll_items
        .not_voided
        .includes(employee: :department)
        .lock
        .order(:id)
        .to_a

      snapshot = {
        "version" => 1,
        "period" => {
          "id" => source_pay_period.id,
          "start_date" => source_pay_period.start_date.iso8601,
          "end_date" => source_pay_period.end_date.iso8601,
          "pay_date" => source_pay_period.pay_date.iso8601,
          "status" => source_pay_period.status,
          "period_description" => source_pay_period.period_description
        },
        "items" => source_items.map { |item| item_snapshot(item) }
      }
      snapshot = JSON.parse(JSON.generate(snapshot))
      checksum = TrainingReplayBenchmark.checksum_for(snapshot)

      TrainingReplayBenchmark.create!(
        company: company,
        pay_period: pay_period,
        source_company: source_pay_period.company,
        source_pay_period: source_pay_period,
        captured_by: actor,
        source_status: source_pay_period.status,
        snapshot: snapshot,
        sha256: checksum,
        captured_at: Time.current
      )
    end

    def self.item_snapshot(item)
      employee = item.employee
      {
        "source_payroll_item_id" => item.id,
        "source_employee_id" => item.employee_id,
        "employee_name" => employee.full_name,
        "department_name" => employee.department&.name,
        "salary_type" => employee.salary_type
      }.merge(ITEM_FIELDS.index_with { |field| item.public_send(field) })
    end
    private_class_method :item_snapshot
  end
end
