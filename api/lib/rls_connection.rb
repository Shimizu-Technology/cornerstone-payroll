# frozen_string_literal: true

module RlsConnection
  READ_SETTINGS = <<~SQL.squish.freeze
    SELECT coalesce(current_setting('app.current_company_id', true), ''),
           coalesce(current_setting('app.rls_mode', true), '')
  SQL
  WRITE_SETTINGS = <<~SQL.squish.freeze
    SELECT set_config('app.current_company_id', $1, false),
           set_config('app.rls_mode', $2, false)
  SQL

  def tenant_settings_active?
    @payroll_tenant_settings.present? && owner == ActiveSupport::IsolatedExecutionState.context
  end

  def with_tenant_settings(company_id, mode)
    previous = nil
    with_raw_connection(materialize_transactions: false) do |raw|
      previous = raw.exec(READ_SETTINGS, &:values).fetch(0)
      raw.exec_params(WRITE_SETTINGS, [ company_id.to_s, mode ], &:clear)
    end
    clear_query_cache
    @payroll_tenant_settings = [ company_id.to_s, mode ]
    yield
  ensure
    @payroll_tenant_settings = nil
    restore_tenant_settings(previous || [ "", "" ])
    clear_query_cache
  end

  def reset_tenant_settings
    return unless RlsContextGuard.enabled? && pool.db_config.primary?

    @payroll_tenant_settings = nil
    restore_tenant_settings([ "", "" ])
  end

  private

  # Cached tenant rows are only usable inside the lease that produced them.
  # Outside a scope, run through the normal adapter log/guard before executing.
  def cache_sql(...)
    return yield if RlsContextGuard.enabled? && pool.db_config.primary? && !tenant_settings_active?

    super
  end

  def lookup_sql_cache(...)
    return if RlsContextGuard.enabled? && pool.db_config.primary? && !tenant_settings_active?

    super
  end

  def restore_tenant_settings(settings)
    @raw_connection&.exec_params(WRITE_SETTINGS, settings, &:clear)
  rescue PG::Error
    # A failed transaction or dead socket must never return to the pool with
    # session settings intact. Rails will reconnect on the next use.
    disconnect!
  end

  def configure_connection
    super
    if @payroll_tenant_settings
      @raw_connection.exec_params(WRITE_SETTINGS, @payroll_tenant_settings, &:clear)
    end
  end

  # The adapter emits sql.active_record inside #log. Check before yielding to
  # the execution block, so rejected statements cannot write rows even in shadow.
  def log(sql, ...)
    if RlsContextGuard.check!(self, sql)
      with_tenant_settings(nil, "system") { super }
    else
      super
    end
  end
end
