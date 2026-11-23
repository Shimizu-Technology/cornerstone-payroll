# frozen_string_literal: true

require Rails.root.join("lib/rls_configuration")
require Rails.root.join("lib/rls_connection")
require Rails.root.join("lib/rls_database")
require "active_record/connection_adapters/postgresql_adapter"

adapter = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
adapter.prepend(RlsConnection)
adapter.set_callback :checkout, :after, :reset_tenant_settings
adapter.set_callback :checkin, :before, :reset_tenant_settings

Rails.application.config.after_initialize do
  RlsConfiguration.verify_boot!(environment: Rails.env) do
    ActiveRecord::Base.connection_pool.with_connection { |connection| RlsDatabase.verify_runtime!(connection) }
  end
end
