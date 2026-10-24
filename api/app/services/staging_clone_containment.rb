# frozen_string_literal: true

class StagingCloneContainment
  QUEUE_TABLES = %w[solid_queue_ready_executions solid_queue_scheduled_executions solid_queue_claimed_executions solid_queue_blocked_executions solid_queue_failed_executions solid_queue_recurring_executions solid_queue_recurring_tasks solid_queue_pauses solid_queue_semaphores solid_queue_processes].freeze
  DISPATCH = { "aire_payroll_acknowledgements" => "delivered_at IS NULL", "aire_payroll_entry_acknowledgements" => "delivered_at IS NULL", "time_tracking_correction_receipts" => "delivered_at IS NULL", "aire_payroll_calendar_publications" => "delivery_status IN ('pending', 'failed')", "invoice_send_schedules" => "status IN ('pending', 'queued', 'sending', 'failed')", "payroll_reminder_configs" => "enabled = TRUE", "invoice_recurrences" => "active = TRUE", "pay_periods" => "tax_sync_status IN ('pending', 'syncing', 'failed')", "historical_client_bootstraps" => "status IN ('pending', 'failed')", "historical_client_bootstrap_dispatches" => "completed_at IS NULL" }.freeze
  TOKEN_TABLES = %w[user_sessions time_tracking_delegations cable_connection_tickets].freeze

  def initialize(env: ENV, connection: ActiveRecord::Base.connection)
    @env = env
    @connection = connection
  end

  # Default is a read-only plan. APPLY=true is deliberately explicit.
  def quarantine(apply: false)
    guard!
    return counts if !apply || StagingQuarantine.suppressed?("__quarantine_complete__", 0)

    connection.transaction do
      connection.execute("SELECT pg_advisory_xact_lock(782041024)")
      create_manifest!
      return counts if marker?("__quarantine_complete__")
      capture("solid_queue_jobs", "finished_at IS NULL") if table?("solid_queue_jobs")
      QUEUE_TABLES.each do |table|
        next unless table?(table)
        capture(table)
        relation(table).delete_all
      end
      connection.execute("UPDATE solid_queue_jobs SET finished_at = CURRENT_TIMESTAMP WHERE finished_at IS NULL") if table?("solid_queue_jobs")
      DISPATCH.each { |table, predicate| capture(table, predicate) if table?(table) }
      TOKEN_TABLES.each do |table|
        next unless table?(table)
        capture(table)
        relation(table).delete_all
      end
      connection.execute("UPDATE invoice_send_schedules SET status = 'cancelled', last_error = 'STAGING clone quarantine' WHERE status IN ('pending', 'queued', 'sending', 'failed')") if table?("invoice_send_schedules")
      connection.execute("UPDATE invoice_recurrences SET active = FALSE WHERE active = TRUE")
      connection.execute("UPDATE payroll_reminder_configs SET enabled = FALSE WHERE enabled = TRUE")
      connection.execute("UPDATE finance_api_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE revoked_at IS NULL") if table?("finance_api_tokens")
      connection.execute("UPDATE user_invitations SET token = md5(random()::text || id::text) WHERE accepted_at IS NULL") if table?("user_invitations")
      mark!("__quarantine_complete__")
    end
    counts
  end

  def configure(apply: false)
    guard!
    return counts if marker?("__containment_complete__")
    unless TimeTrackingSource.column_names.include?("authorization_origin")
      raise StagingOutboundPolicy::ConfigurationError, "Migrate the quarantined clone with db:safe_prepare before staging:clone:configure"
    end
    testers = StagingOutboundPolicy.bindings(env)
    testers.each_key do |email|
      count = User.unscoped.where("lower(email) = ?", email).count
      raise StagingOutboundPolicy::ConfigurationError, "Each STAGING_TESTER_BINDINGS email must match exactly one existing user" unless count == 1
    end
    url = StagingOutboundPolicy.require_setting!("STAGING_AIRE_BASE_URL", env)
    StagingOutboundPolicy.integration!(url, env: env)
    authorization_origin = StagingOutboundPolicy.require_setting!("STAGING_AIRE_FRONTEND_ORIGIN", env)
    StagingOutboundPolicy.frontend_origin!(authorization_origin, env: env)
    secret = StagingOutboundPolicy.require_setting!("STAGING_PAYROLL_SHARED_SECRET", env)
    raise StagingOutboundPolicy::ConfigurationError, "STAGING_PAYROLL_SHARED_SECRET must have at least 32 characters" if secret.length < 32
    return counts unless apply
    raise StagingOutboundPolicy::ConfigurationError, "Run staging:clone:quarantine with APPLY=true first" unless marker?("__quarantine_complete__")
    connection.transaction do
      # update_columns deliberately avoids production connection callbacks; encrypted
      # attributes still pass through Active Record's encrypted attribute type.
      TimeTrackingSource.unscoped.find_each do |source|
        if source.source_type == "aire_services"
          source.update_columns(base_url: url, authorization_origin: authorization_origin, shared_secret: secret) unless source.base_url == url && source.shared_secret == secret && source.authorization_origin == authorization_origin
        else
          source.update_columns(active: false) if source.active?
        end
      end
      connection.execute("UPDATE users SET clerk_id = NULL, clerk_invitation_id = NULL, workos_id = NULL, last_session_id_digest = NULL WHERE clerk_id IS NOT NULL OR clerk_invitation_id IS NOT NULL OR workos_id IS NOT NULL OR last_session_id_digest IS NOT NULL")
      testers.each do |email, clerk_id|
        User.unscoped.where("lower(email) = ?", email).update_all(clerk_id: clerk_id)
      end
      mark!("__containment_complete__")
    end
    counts
  end

  def counts
    guard!
    result = {}
    ([ "solid_queue_jobs" ] + QUEUE_TABLES + DISPATCH.keys + TOKEN_TABLES).uniq.each do |table|
      next unless table?(table)
      predicate = DISPATCH[table] || (table == "solid_queue_jobs" ? "finished_at IS NULL" : "TRUE")
      count = relation(table).where(predicate).count
      suppressed = table?(StagingQuarantine::TABLE) ? StagingQuarantine.records.where(source_table: table).count : 0
      result[table] = { candidates: count, quarantined: suppressed }
    end
    result["containment_complete"] = marker?("__containment_complete__") ? 1 : 0
    result
  end

  private

  attr_reader :env, :connection

  def guard!
    StagingOutboundPolicy.validate_database!(env: env)
    actual_host = connection.pool.db_config.configuration_hash[:host].to_s.downcase
    approved = StagingOutboundPolicy.list("STAGING_DATABASE_HOSTS", env)
    denied = StagingOutboundPolicy.list("PRODUCTION_DATABASE_HOSTS", env)
    unless approved.include?(actual_host) && !denied.include?(actual_host)
      raise StagingOutboundPolicy::ConfigurationError, "Actual database connection failed STAGING_DATABASE_HOSTS assertion"
    end
    true
  end

  def table?(table)
    connection.data_source_exists?(table)
  end

  def relation(table)
    @relations ||= {}
    @relations[table] ||= Class.new(ActiveRecord::Base) do
      self.table_name = table
      self.inheritance_column = "_disabled_type"
    end.unscoped
  end

  def create_manifest!
    connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS staging_quarantines (
        source_table text NOT NULL,
        source_id bigint NOT NULL,
        original_state text,
        quarantined_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (source_table, source_id)
      )
    SQL
    StagingQuarantine::Record.reset_column_information
  end

  def capture(table, predicate = "TRUE")
    columns = connection.columns(table).map(&:name)
    state = if columns.include?("delivery_status") then :delivery_status
    elsif columns.include?("status") then :status
    end
    relation(table).where(predicate).in_batches(of: 1_000) do |batch|
      rows = state ? batch.pluck(:id, state) : batch.pluck(:id).map { |id| [ id, nil ] }
      manifest = rows.map { |id, old_state| { source_table: table, source_id: id, original_state: old_state } }
      StagingQuarantine.records.insert_all(manifest, unique_by: %i[source_table source_id]) unless manifest.empty?
    end
  end

  def marker?(name)
    table?(StagingQuarantine::TABLE) && StagingQuarantine.records.where(source_table: name, source_id: 0).exists?
  end

  def mark!(name)
    StagingQuarantine.records.insert_all([ { source_table: name, source_id: 0 } ], unique_by: %i[source_table source_id])
  end
end
