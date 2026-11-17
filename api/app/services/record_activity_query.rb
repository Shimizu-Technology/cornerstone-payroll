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
  # Rows the run's feed leaves out unless asked: editor data the report panel
  # loads before a document is made (the document itself is listed), and
  # workers or clients opening a pay stub.
  HIDDEN_DETAIL_ACTIONS = %w[
    reports#transmittal_preview reports#check_signoff_preview
    worker_statement#viewed worker_statement#pdf_downloaded client_pay_stubs#download
  ].freeze
  # Client-wide check settings share the "checks" record type but no run.
  COMPANY_CHECK_ACTIONS = %w[
    checks#update_check_settings checks#test_check_pdf checks#alignment_test_pdf checks#update_next_check_number
  ].freeze
  # Older rows name the run only through one of its own records.
  RUN_CHILD_RECORDS = {
    "payroll_items" => %w[payroll_items checks PayrollItem],
    "check_print_runs" => %w[check_print_runs],
    "check_print_generations" => %w[check_print_generations],
    "payroll_review_packages" => %w[PayrollReviewPackage]
  }.freeze

  def initialize(record_type:, record_id:, company_id:, include_hidden_details: false)
    @record_type = record_type.to_s
    @record_id = record_id
    @company_id = company_id
    @include_hidden_details = include_hidden_details
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

    logs = AuditLog.where(company_id: company_id)
    return logs.where(record_id: record.id, record_type: definition.fetch(:audit_aliases)) unless definition[:pay_run_feed]

    logs = logs.where(id: pay_run_log_ids)
    include_hidden_details ? logs : logs.where.not(action: HIDDEN_DETAIL_ACTIONS)
  end

  def hidden_detail_count
    return 0 if include_hidden_details || !RECORD_TYPES.dig(record_type, :pay_run_feed)

    AuditLog.where(id: pay_run_log_ids, action: HIDDEN_DETAIL_ACTIONS).count
  end

  private

  attr_reader :record_type, :record_id, :company_id, :include_hidden_details

  # Everything done inside one pay run. Each arm
  # can use its own index: new rows carry metadata.pay_period_id, older rows
  # are found through the run's own items, imports, packages and revisions.
  # The UNION stays in the database as a subquery, so a long run never sends
  # a large list of IDs back and forth.
  def pay_run_log_ids
    AuditLog.unscoped.from(Arel.sql("(#{pay_run_log_ids_sql}) AS audit_logs")).select(:id)
  end

  def pay_run_log_ids_sql
    @pay_run_log_ids_sql ||= begin
      child_arms = RUN_CHILD_RECORDS.map do |table, record_types|
        excluded = table == "payroll_items" ? "AND audit_logs.action NOT IN (:company_check_actions)" : ""
        <<~SQL
          SELECT audit_logs.id FROM audit_logs
          JOIN #{table} ON #{table}.id = audit_logs.record_id AND #{table}.pay_period_id = :record_id
          WHERE audit_logs.company_id = :company_id
            AND audit_logs.record_type IN (#{record_types.map { |type| AuditLog.connection.quote(type) }.join(', ')}) #{excluded}
        SQL
      end
      sql = ([ <<~SQL ] + child_arms).join(" UNION ")
        SELECT id FROM audit_logs
        WHERE company_id = :company_id AND record_type IN (:record_aliases) AND record_id = :record_id
        UNION
        SELECT id FROM audit_logs WHERE company_id = :company_id AND (metadata ->> 'pay_period_id') = :metadata_record_id
        UNION
        SELECT id FROM audit_logs WHERE company_id = :company_id AND record_type = 'payroll_imports' AND record_id = :record_id
      SQL
      AuditLog.sanitize_sql_array([
        sql.squish,
        { company_id: company_id, record_aliases: RECORD_TYPES.dig(record_type, :audit_aliases),
          company_check_actions: COMPANY_CHECK_ACTIONS, record_id: record.id, metadata_record_id: record.id.to_s }
      ])
    end
  end
end
