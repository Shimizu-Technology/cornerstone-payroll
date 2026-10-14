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
    sql = File.read(PATH)
    declarations = sql.scan(/CREATE OR REPLACE FUNCTION\s+(\w+)/).flatten
    definitions = sql.scan(/CREATE OR REPLACE FUNCTION\s+(\w+)\([^)]*\)(.*?)(\$[a-zA-Z0-9_]*\$)(.*?)\3(.*?);/m)
    unless definitions.map(&:first) == declarations
      raise "Payroll integrity snapshot contains an unrecognized function definition"
    end
    expected_functions = definitions.to_h do |name, header, _delimiter, body, tail|
      language = "#{header} #{tail}"[/LANGUAGE\s+(\w+)/, 1]
      raise "Payroll integrity function language missing: #{name}" unless language
      [ name, [ body.strip, language ] ]
    end
    functions = connection.select_rows(<<~SQL).to_h { |name, body, language| [ name, [ body.strip, language ] ] }
      SELECT p.proname, p.prosrc, l.lanname FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_language l ON l.oid = p.prolang
      WHERE n.nspname = current_schema()
    SQL
    altered = expected_functions.reject { |name, definition| functions[name] == definition }.keys
    raise "Payroll database integrity functions differ: #{altered.join(', ')}" if altered.any?
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
