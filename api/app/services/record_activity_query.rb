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
      pay_run_feed: true
    }
  }.freeze
  # Editor data the report panel loads before a document is made. The document
  # itself is audited separately, so these stay out of the run's default feed.
  REPORT_DETAIL_ACTIONS = %w[reports#transmittal_preview reports#check_signoff_preview].freeze
  # Client-wide check settings share the "checks" record type but no run.
  COMPANY_CHECK_ACTIONS = %w[
    checks#update_check_settings checks#test_check_pdf checks#alignment_test_pdf checks#update_next_check_number
  ].freeze

  def initialize(record_type:, record_id:, company_id:, include_report_details: false)
    @record_type = record_type.to_s
    @record_id = record_id
    @company_id = company_id
    @include_report_details = include_report_details
  end

  def record
    return @record if defined?(@record)

    definition = RECORD_TYPES[record_type]
    raise RecordNotFoundError unless definition

    scope = definition.fetch(:model).where(id: record_id)
    scope = record_type == "companies" ? scope.where(id: company_id) : scope.where(company_id: company_id)
    @record = scope.first || raise(RecordNotFoundError)
  end

  def call
    definition = RECORD_TYPES[record_type]
    raise RecordNotFoundError unless definition

    record = self.record

    logs = AuditLog.where(company_id: company_id)
    return logs.where(record_id: record.id, record_type: definition.fetch(:audit_aliases)) unless definition[:pay_run_feed]

    logs = pay_run_logs(logs, record, definition.fetch(:audit_aliases))
    include_report_details ? logs : logs.where.not(action: REPORT_DETAIL_ACTIONS)
  end

  def hidden_report_detail_count
    return 0 if include_report_details || !RECORD_TYPES.dig(record_type, :pay_run_feed)

    pay_run_logs(AuditLog.where(company_id: company_id), record, RECORD_TYPES.dig(record_type, :audit_aliases))
      .where(action: REPORT_DETAIL_ACTIONS).count
  end

  private

  attr_reader :record_type, :record_id, :company_id, :include_report_details

  # Everything done inside one pay run. New rows carry metadata.pay_period_id;
  # older rows are found through the run's own items, imports and packages.
  def pay_run_logs(logs, record, aliases)
    logs.where(
      <<~SQL.squish,
        (record_type IN (:record_aliases) AND record_id = :record_id)
        OR (metadata ->> 'pay_period_id') = :metadata_record_id
        OR (record_type = 'payroll_imports' AND record_id = :record_id)
        OR (record_type IN ('payroll_items', 'checks', 'PayrollItem') AND action NOT IN (:company_check_actions)
          AND record_id IN (SELECT id FROM payroll_items WHERE pay_period_id = :record_id))
        OR (record_type = 'check_print_runs'
          AND record_id IN (SELECT id FROM check_print_runs WHERE pay_period_id = :record_id))
        OR (record_type = 'check_print_generations'
          AND record_id IN (SELECT id FROM check_print_generations WHERE pay_period_id = :record_id))
        OR (record_type = 'PayrollReviewPackage'
          AND record_id IN (SELECT id FROM payroll_review_packages WHERE pay_period_id = :record_id))
      SQL
      record_aliases: aliases,
      company_check_actions: COMPANY_CHECK_ACTIONS,
      record_id: record.id,
      metadata_record_id: record.id.to_s
    )
  end
end
