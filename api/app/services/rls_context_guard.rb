# frozen_string_literal: true

require Rails.root.join("lib/rls_configuration")
require Rails.root.join("lib/rls_tables")

class RlsContextGuard
  def self.mode
    RlsConfiguration.mode
  end

  def self.enabled?
    mode != "off"
  end

  def self.check!(connection, sql)
    return unless enabled? && connection.pool.db_config&.primary?
    return if TenantScope.current && connection.tenant_settings_active?

    # A PostgreSQL parser handles quoted identifiers, joins, CTEs and writes
    # without confusing relation names with SQL comments or string literals.
    tables = PgQuery.summary(sql).tables.filter_map do |name|
      table = name.split(".").last
      table if RlsTables::PROTECTED_TABLES.include?(table)
    end.uniq.sort
    return if tables.empty?

    report_missing_context(connection, tables: tables)
  rescue PgQuery::ParseError
    # Let PostgreSQL report the syntax error. Log only a fixed event name if
    # the parser cannot classify a statement, since SQL can contain literals.
    report_missing_context(connection, tables: [], event: "rls_unclassified_sql")
  end

  def self.report_missing_context(connection, **details)
    bypass = RlsDatabase.bypass_enabled?(connection)
    report!(**details, bypass: bypass)
    bypass
  end
  private_class_method :report_missing_context

  def self.report!(tables:, bypass: false, event: "rls_missing_context")
    frames = caller_locations.filter_map do |location|
      path = location.absolute_path.to_s.delete_prefix("#{Rails.root}/")
      next unless path.match?(%r{\A(?:app|lib|db|config)/})
      next if path.start_with?("app/services/rls_context_guard.rb", "lib/rls_connection.rb")

      "#{path}:#{location.lineno}:in `#{location.base_label}'"
    end.first(8)
    ActiveSupport::Notifications.instrument("rls.context_violation", tables: tables, call_site: frames.first)
    if mode == "raise" && !bypass
      raise TenantScope::MissingContextError, "#{event}: #{tables.join(', ')} (#{frames.first})"
    end

    PayrollTelemetry.log(:warn, event, tables: tables, call_site: frames.first,
      backtrace: frames, request_id: Current.request_id)
  end
  private_class_method :report!
end
