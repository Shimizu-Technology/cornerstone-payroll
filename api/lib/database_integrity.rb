# frozen_string_literal: true

# Ruby schema dumps cannot represent PostgreSQL functions and triggers. This
# versioned snapshot restores the current migration-defined guards without
# replaying data migrations or rebuilding any application table.
module DatabaseIntegrity
  PATH = File.expand_path("../db/integrity.sql", __dir__)

  def self.install!(connection = ActiveRecord::Base.connection)
    raise "Payroll database integrity requires PostgreSQL" unless connection.adapter_name == "PostgreSQL"
    connection.transaction do
      connection.execute(File.read(PATH))
      verify!(connection)
    end
    true
  end

  def self.verify!(connection = ActiveRecord::Base.connection)
    expected = File.read(PATH).scan(/CREATE TRIGGER\s+(\w+).*?\bON\s+(\w+)/m).uniq
    actual = connection.select_rows(<<~SQL)
      SELECT t.tgname, c.relname FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema() AND NOT t.tgisinternal AND t.tgenabled <> 'D'
    SQL
    missing = expected - actual
    raise "Payroll database integrity guards missing: #{missing.map(&:first).join(', ')}" if missing.any?
    true
  end

  module SchemaDefinition
    def define(*args, **options, &block)
      result = super
      DatabaseIntegrity.install!
      result
    end
  end
end
