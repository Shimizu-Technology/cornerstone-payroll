# frozen_string_literal: true

require "prism"

module CompensationWriteLint
  SCANNED_PATHS = %w[app lib config db/seeds.rb db/seeds script scripts].freeze
  ALLOWED_FILES = %w[app/services/employee_compensation_change_service.rb lib/compensation_write_lint.rb].freeze
  BYPASS_METHODS = %i[
    update_columns update_column update_all update_attribute update_attribute! update_counters
    insert insert! insert_all insert_all! upsert upsert_all delete delete_all
  ].freeze
  RATE_RECEIVERS = /\b(?:EmployeeWageRate|employee_wage_rates)\b/
  HISTORY_RECEIVERS = /\b(?:EmployeeCompensationChange|EmployeeWageRateVersion|employee_compensation_changes|employee_wage_rate_versions)\b/
  PAYROLL_ITEM_RECEIVERS = /\b(?:PayrollItem|payroll_items?)\b/
  PROTECTED_TABLE = /employee_wage_rate(?:s|_versions)|employee_compensation_changes/
  SQL_TABLE = /(?:["\w]+\s*\.\s*)?"?/
  SQL_COMMAND = /\b(?:UPDATE\s+(?:ONLY\s+)?|INSERT\s+INTO\s+|DELETE\s+FROM\s+|TRUNCATE\s+(?:TABLE\s+)?)/i
  SQL_WRITE = /#{SQL_COMMAND}#{SQL_TABLE}(?:#{PROTECTED_TABLE})\b/i
  EMPLOYEE_SQL_WRITE = /#{SQL_COMMAND}#{SQL_TABLE}employees"?\b([^;]*)/i

  Offense = Struct.new(:path, :line, :rule, :excerpt, keyword_init: true) do
    def to_s
      "#{path}:#{line}: #{rule}: #{excerpt}"
    end
  end

  class Scanner < Prism::Visitor
    attr_reader :offenses

    def initialize(source, path)
      @lines = source.lines
      @path = path
      @offenses = []
      @locals = [ {} ]
    end

    def visit_def_node(node)
      @locals.push({})
      super
    ensure
      @locals.pop
    end

    def visit_local_variable_write_node(node)
      @locals.last[node.name] = [ evidence(node.value), receiver_evidence(node.value) ]
      super
    end

    def visit_call_node(node)
      method = node.name
      if %i[send public_send __send__].include?(method)
        argument = node.arguments&.arguments&.first
        method = argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
      end
      if BYPASS_METHODS.include?(method)
        receiver = receiver_evidence(node.receiver)
        arguments = evidence(node.arguments)
        if receiver.match?(RATE_RECEIVERS)
          flag(node, "bulk or callback-skipping write on employee wage rates")
        elsif receiver.match?(HISTORY_RECEIVERS)
          flag(node, "bulk write on compensation history")
        elsif !%i[delete delete_all].include?(method) && named_attribute?(arguments, "pay_rate") && !receiver.match?(PAYROLL_ITEM_RECEIVERS)
          flag(node, "bulk or callback-skipping write naming pay_rate")
        elsif !receiver.match?(PAYROLL_ITEM_RECEIVERS) && (
            !%i[delete delete_all].include?(method) &&
            EmployeeCompensationChangeService::BASIS_ATTRIBUTES.any? { |field| named_attribute?(arguments, field) }
          )
          flag(node, "bulk or callback-skipping write on employee compensation")
        end
      end
      if node.name == :+ && (sql = static_string(node))
        check_sql(node, sql)
      else
        super
      end
    end

    def visit_string_node(node)
      check_sql(node, node.unescaped)
    end

    def visit_interpolated_string_node(node)
      if (sql = static_string(node))
        check_sql(node, sql)
      else
        super
      end
    end

    private

    def check_sql(node, sql)
      sql = sql.scrub
      if sql.match?(SQL_WRITE) || sql.scan(EMPLOYEE_SQL_WRITE).flatten.any? do |statement|
        sql.match?(/\b(?:DELETE\s+FROM|TRUNCATE)\b/i) ||
          EmployeeCompensationChangeService::COMPENSATION_ATTRIBUTES.any? { |field| statement.match?(/\b#{field}\b/i) }
      end
        flag(node, "raw SQL write on pay rates or compensation history")
      end
    end

    def static_string(node)
      case node
      when Prism::StringNode
        node.unescaped
      when Prism::InterpolatedStringNode
        node.parts.map { |part| static_string(part) }.then { |parts| parts.join if parts.all? }
      when Prism::CallNode
        return unless node.name == :+ && node.arguments&.arguments&.one?

        left = static_string(node.receiver)
        right = static_string(node.arguments.arguments.first)
        left + right if left && right
      end
    end

    def named_attribute?(arguments, name)
      arguments.match?(/(?:\b#{name}:|:#{name}\b|["']#{name}["'])/)
    end

    def flag(node, rule)
      line = node.location.start_line
      offenses << Offense.new(path: @path, line: line, rule: rule, excerpt: @lines[line - 1].to_s.strip)
    end

    def receiver_evidence(node)
      case node
      when Prism::CallNode then [ receiver_evidence(node.receiver), node.name ].join(" ")
      when Prism::LocalVariableReadNode then @locals.last[node.name]&.last || node.slice
      when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::InstanceVariableReadNode then node.slice
      else ""
      end
    end

    def evidence(node)
      return "" unless node
      return (@locals.last[node.name]&.first || node.slice) if node.is_a?(Prism::LocalVariableReadNode)

      [ node.slice, *node.compact_child_nodes.map { |child| evidence(child) } ].join(" ")
    end
  end

  def self.offenses(root: Rails.root)
    root = Pathname(root)
    SCANNED_PATHS.flat_map do |entry|
      path = root.join(entry)
      files = path.directory? ? Pathname.glob(path.join("**/*.{rb,rake,sql}")) : [ path ].select(&:file?)
      files.flat_map do |file|
        relative = file.relative_path_from(root).to_s
        ALLOWED_FILES.include?(relative) ? [] : scan(file.read, relative)
      end
    end
  end

  def self.scan(source, relative_path)
    scanner = Scanner.new(source, relative_path)
    # Parse stand-alone SQL as a Ruby heredoc so the same SQL check runs.
    code = relative_path.end_with?(".sql") ? "<<'SQL'\n#{source}\nSQL\n" : source
    scanner.visit(Prism.parse(code).value)
    scanner.offenses.uniq
  end
end
