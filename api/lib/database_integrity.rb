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
      WHERE n.nspname = current_schema() AND NOT t.tgisinternal AND t.tgenabled IN ('O', 'A')
    SQL
    missing = expected - actual
    raise "Payroll database integrity guards missing: #{missing.map(&:first).join(', ')}" if missing.any?
    sql = File.read(PATH)
    namespace = connection.select_value("SELECT current_schema()")
    expected_triggers = sql.scan(/CREATE TRIGGER\s+(\w+)(.*?);/m).to_h do |name, definition|
      [ name, normalize_trigger("CREATE TRIGGER #{name}#{definition}", namespace) ]
    end
    installed_triggers = connection.select_rows(<<~SQL).to_h
      SELECT t.tgname, pg_get_triggerdef(t.oid) FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema() AND NOT t.tgisinternal
    SQL
    changed = expected_triggers.reject { |name, definition| normalize_trigger(installed_triggers.fetch(name), namespace) == definition }.keys
    raise "Payroll database integrity trigger definitions differ: #{changed.join(', ')}" if changed.any?
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

  def self.normalize_trigger(definition, namespace)
    # PostgreSQL qualifies table names and canonicalizes event order. Preserve
    # every other clause, including UPDATE columns, row/statement scope,
    # predicate and invoked function, so a rewired named guard cannot pass.
    definition.gsub(/(?:#{Regexp.escape(namespace)}|#{Regexp.escape(%("#{namespace}"))})\./, "")
      .gsub(/\s+/, " ").strip.sub(/;\z/, "")
      .sub(/\b(BEFORE|AFTER|INSTEAD OF) (.*?) ON /) { "#{$1} #{$2.split(' OR ').sort.join(' OR ')} ON " }
  end

  module SchemaDefinition
    def define(*args, **options, &block)
      # Rails temporarily selects the schema target pool while loading each
      # database. Secondary Solid Cache/Queue/Cable schemas have no payroll tables.
      schema_pool = connection_pool
      result = super
      if schema_pool.db_config.primary?
        schema_pool.with_connection { |connection| DatabaseIntegrity.install!(connection) }
      end
      result
    end
  end
end
