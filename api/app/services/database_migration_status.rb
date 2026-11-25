# frozen_string_literal: true

# Reports whether every configured database has run all of its migrations.
#
# ActiveRecord::Migration.check_all_pending! points ActiveRecord::Base at each
# database config in turn and then reconnects it to the primary. With more than
# one database, that disconnects the connection that holds an active TenantScope
# lease. Later queries in the same scope run on a new connection without tenant
# settings, and the raise-mode RLS guard rejects them. This check reads each
# database through the pool it already has, or through a separately named
# temporary pool, and never replaces ActiveRecord::Base's pool.
module DatabaseMigrationStatus
  TEMPORARY_POOL_PREFIX = "DatabaseMigrationStatus"

  def self.current?(env_name: Rails.env, handler: ActiveRecord::Base.connection_handler)
    ActiveRecord::Base.configurations.configs_for(env_name: env_name.to_s).none? do |db_config|
      with_pool(db_config, handler) { |pool| pool.migration_context.needs_migration? }
    end
  end

  def self.with_pool(db_config, handler)
    existing = handler.connection_pool_list.find do |pool|
      pool.db_config.env_name == db_config.env_name && pool.db_config.name == db_config.name
    end
    return yield existing if existing

    owner_name = "#{TEMPORARY_POOL_PREFIX}::#{db_config.name}"
    begin
      yield handler.establish_connection(db_config, owner_name: owner_name)
    ensure
      handler.remove_connection_pool(owner_name)
    end
  end
  private_class_method :with_pool
end
