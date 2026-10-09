# frozen_string_literal: true

class ExpandEmployeeW4ElectionSources < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  TABLE = :employee_w4_elections
  CONSTRAINT = "employee_w4_elections_source_check"
  ORIGINAL_SOURCES = %w[staff client_approved employee_creation legacy_profile quickbooks_history].freeze
  EXPANDED_SOURCES = (ORIGINAL_SOURCES + [ "default_withholding" ]).freeze

  def up
    replace_constraint!(EXPANDED_SOURCES, "employee_w4_elections_source_expanded_check")
  end

  def down
    replace_constraint!(ORIGINAL_SOURCES, "employee_w4_elections_source_original_check")
  end

  private

  def replace_constraint!(sources, temporary_name)
    current = connection.check_constraints(TABLE).find { |constraint| constraint.name == CONSTRAINT }
    raise "Missing original employee withholding source constraint" unless current
    if source_values(current) == sources.sort
      validate_check_constraint TABLE, name: CONSTRAINT unless current.validate?
      connection.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        remove_known_temporary_constraints!
      end
      return
    end

    temporary = connection.check_constraints(TABLE).find { |constraint| constraint.name == temporary_name }
    if temporary && source_values(temporary) != sources.sort
      raise "Unexpected temporary employee withholding source constraint"
    end
    unless temporary
      connection.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        add_check_constraint TABLE, "source IN (#{sources.map { |source| connection.quote(source) }.join(', ')})",
          name: temporary_name, validate: false
      end
    end

    # The existing constraint stays enforced during the table scan. NOT VALID
    # also checks new writes, and validation avoids an exclusive table scan.
    validate_check_constraint TABLE, name: temporary_name

    # Only the short name swap needs an exclusive lock. A busy table causes a
    # retry instead of holding new writes behind a long lock wait.
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      remove_known_temporary_constraints!(except: temporary_name)
      remove_check_constraint TABLE, name: CONSTRAINT
      execute "ALTER TABLE #{connection.quote_table_name(TABLE)} RENAME CONSTRAINT #{connection.quote_column_name(temporary_name)} TO #{connection.quote_column_name(CONSTRAINT)}"
    end
  rescue ActiveRecord::StatementInvalid => e
    # A rollback with existing default-withholding rows cannot validate the
    # narrower source set. Preserve those rows and the expanded constraint;
    # remove the unsuccessful temporary restriction before reporting failure.
    if e.cause.is_a?(PG::CheckViolation) && connection.check_constraints(TABLE).any? { |constraint| constraint.name == CONSTRAINT }
      connection.transaction do
        execute "SET LOCAL lock_timeout = '5s'"
        remove_check_constraint TABLE, name: temporary_name if connection.check_constraint_exists?(TABLE, name: temporary_name)
      end
    end
    raise
  end

  def remove_known_temporary_constraints!(except: nil)
    {
      "employee_w4_elections_source_expanded_check" => EXPANDED_SOURCES,
      "employee_w4_elections_source_original_check" => ORIGINAL_SOURCES
    }.each do |name, sources|
      next if name == except
      constraint = connection.check_constraints(TABLE).find { |candidate| candidate.name == name }
      next unless constraint
      raise "Unexpected temporary employee withholding source constraint" unless source_values(constraint) == sources.sort

      remove_check_constraint TABLE, name: name
    end
  end

  def source_values(constraint)
    constraint.expression.scan(/'([^']+)'/).flatten.sort
  end
end
