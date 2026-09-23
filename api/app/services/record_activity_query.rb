# frozen_string_literal: true

class RecordActivityQuery
  class RecordNotFoundError < StandardError; end

  RECORD_TYPES = {
    "employees" => {
      model: Employee,
      audit_aliases: %w[Employee employees client_employees]
    },
    "pay_periods" => {
      model: PayPeriod,
      audit_aliases: %w[PayPeriod pay_periods]
    }
  }.freeze

  def initialize(record_type:, record_id:, company_id:)
    @record_type = record_type.to_s
    @record_id = record_id
    @company_id = company_id
  end

  def call
    definition = RECORD_TYPES[record_type]
    raise RecordNotFoundError unless definition

    record = definition.fetch(:model).find_by(id: record_id, company_id: company_id)
    raise RecordNotFoundError unless record

    logs = AuditLog.where(
      company_id: company_id,
      record_id: record.id,
      record_type: definition.fetch(:audit_aliases)
    )

    logs
  end

  private

  attr_reader :record_type, :record_id, :company_id
end
