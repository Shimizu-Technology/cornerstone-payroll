# frozen_string_literal: true

class RecordActivityQuery
  class RecordNotFoundError < StandardError; end

  RECORD_TYPES = {
    "companies" => { model: Company, audit_aliases: %w[Company companies test_workspace migration_rehearsal training_replay] },
    "employees" => {
      model: Employee,
      audit_aliases: %w[Employee employees client_employees]
    },
    "pay_periods" => {
      model: PayPeriod,
      audit_aliases: %w[PayPeriod pay_period payperiod pay_periods],
      linked_report_aliases: %w[reports client_reports]
    }
  }.freeze

  def initialize(record_type:, record_id:, company_id:)
    @record_type = record_type.to_s
    @record_id = record_id
    @company_id = company_id
  end

  def record
    definition = RECORD_TYPES[record_type]
    raise RecordNotFoundError unless definition

    scope = definition.fetch(:model).where(id: record_id)
    scope = record_type == "companies" ? scope.where(id: company_id) : scope.where(company_id: company_id)
    scope.first || raise(RecordNotFoundError)
  end

  def call
    definition = RECORD_TYPES[record_type]
    raise RecordNotFoundError unless definition

    record = self.record

    logs = AuditLog.where(company_id: company_id)
    linked_report_aliases = definition[:linked_report_aliases]
    return logs.where(record_id: record.id, record_type: definition.fetch(:audit_aliases)) unless linked_report_aliases

    logs.where(
      <<~SQL.squish,
        (record_type IN (:record_aliases) AND record_id = :record_id)
        OR
        (record_type IN (:report_aliases) AND metadata ->> 'pay_period_id' = :metadata_record_id)
      SQL
      record_aliases: definition.fetch(:audit_aliases),
      report_aliases: linked_report_aliases,
      record_id: record.id,
      metadata_record_id: record.id.to_s
    )
  end

  private

  attr_reader :record_type, :record_id, :company_id
end
