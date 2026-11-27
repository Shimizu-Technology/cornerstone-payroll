# frozen_string_literal: true

class AddEmployeeLifecycleFoundationsColumnsAndConstraints < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  STATUS_EVENTS_TABLE = :employee_status_events
  STATUS_EVENTS_CONSTRAINT = "employee_status_events_source_check"
  ORIGINAL_STATUS_SOURCES = %w[operator production_migration].freeze
  EXPANDED_STATUS_SOURCES = %w[operator production_migration client_portal].freeze
  STATUS_EXPANDED_TMP = "employee_status_events_source_check_v2"
  STATUS_ORIGINAL_TMP = "employee_status_events_source_check_original"

  W4_TABLE = :employee_w4_elections
  W4_CONSTRAINT = "employee_w4_elections_source_check"
  ORIGINAL_W4_SOURCES = %w[staff client_approved employee_creation legacy_profile quickbooks_history default_withholding].freeze
  EXPANDED_W4_SOURCES = %w[staff client_approved client_direct employee_creation legacy_profile quickbooks_history default_withholding].freeze
  W4_EXPANDED_TMP = "employee_w4_elections_source_check_v2"
  W4_ORIGINAL_TMP = "employee_w4_elections_source_check_original"

  def up
    with_lock_timeout do
      unless column_exists?(:employees, :readiness_gate_enforced)
        add_column :employees, :readiness_gate_enforced, :boolean, null: false, default: false
      end
    end

    with_lock_timeout do
      unless column_exists?(:client_operating_profiles, :lifecycle_mode_activated_at)
        add_column :client_operating_profiles, :lifecycle_mode_activated_at, :datetime
      end
      unless column_exists?(:client_operating_profiles, :lifecycle_mode_activation_failed_at)
        add_column :client_operating_profiles, :lifecycle_mode_activation_failed_at, :datetime
      end
      unless column_exists?(:client_operating_profiles, :lifecycle_mode_activation_blockers)
        add_column :client_operating_profiles, :lifecycle_mode_activation_blockers, :jsonb, null: false, default: {}
      end
    end

    replace_source_constraint!(
      table: STATUS_EVENTS_TABLE,
      constraint_name: STATUS_EVENTS_CONSTRAINT,
      sources: EXPANDED_STATUS_SOURCES,
      temporary_name: STATUS_EXPANDED_TMP,
      known_temporaries: {
        STATUS_EXPANDED_TMP => EXPANDED_STATUS_SOURCES,
        STATUS_ORIGINAL_TMP => ORIGINAL_STATUS_SOURCES
      }
    )

    replace_source_constraint!(
      table: W4_TABLE,
      constraint_name: W4_CONSTRAINT,
      sources: EXPANDED_W4_SOURCES,
      temporary_name: W4_EXPANDED_TMP,
      known_temporaries: {
        W4_EXPANDED_TMP => EXPANDED_W4_SOURCES,
        W4_ORIGINAL_TMP => ORIGINAL_W4_SOURCES
      }
    )
  end

  def down
    replace_source_constraint!(
      table: W4_TABLE,
      constraint_name: W4_CONSTRAINT,
      sources: ORIGINAL_W4_SOURCES,
      temporary_name: W4_ORIGINAL_TMP,
      known_temporaries: {
        W4_EXPANDED_TMP => EXPANDED_W4_SOURCES,
        W4_ORIGINAL_TMP => ORIGINAL_W4_SOURCES
      }
    )

    replace_source_constraint!(
      table: STATUS_EVENTS_TABLE,
      constraint_name: STATUS_EVENTS_CONSTRAINT,
      sources: ORIGINAL_STATUS_SOURCES,
      temporary_name: STATUS_ORIGINAL_TMP,
      known_temporaries: {
        STATUS_EXPANDED_TMP => EXPANDED_STATUS_SOURCES,
        STATUS_ORIGINAL_TMP => ORIGINAL_STATUS_SOURCES
      }
    )

    with_lock_timeout do
      remove_column :client_operating_profiles, :lifecycle_mode_activation_blockers if column_exists?(:client_operating_profiles, :lifecycle_mode_activation_blockers)
      remove_column :client_operating_profiles, :lifecycle_mode_activation_failed_at if column_exists?(:client_operating_profiles, :lifecycle_mode_activation_failed_at)
      remove_column :client_operating_profiles, :lifecycle_mode_activated_at if column_exists?(:client_operating_profiles, :lifecycle_mode_activated_at)
    end

    with_lock_timeout do
      remove_column :employees, :readiness_gate_enforced if column_exists?(:employees, :readiness_gate_enforced)
    end
  end

  private

  def replace_source_constraint!(table:, constraint_name:, sources:, temporary_name:, known_temporaries:)
    current = connection.check_constraints(table).find { |constraint| constraint.name == constraint_name }
    raise "Missing source constraint #{constraint_name} on #{table}" unless current

    if source_values(current) == sources.sort
      validate_check_constraint table, name: constraint_name unless current.validate?
      with_lock_timeout do
        remove_known_temporary_constraints!(table, known_temporaries)
      end
      return
    end

    temporary = connection.check_constraints(table).find { |constraint| constraint.name == temporary_name }
    if temporary && source_values(temporary) != sources.sort
      raise "Unexpected temporary source constraint #{temporary_name} on #{table}"
    end

    unless temporary
      with_lock_timeout do
        add_check_constraint(
          table,
          "source IN (#{sources.map { |source| connection.quote(source) }.join(', ')})",
          name: temporary_name,
          validate: false
        )
      end
    end

    # The existing constraint stays enforced during validation; VALIDATE holds
    # SHARE UPDATE EXCLUSIVE only so concurrent reads and writes are unblocked.
    validate_check_constraint table, name: temporary_name

    with_lock_timeout do
      remove_known_temporary_constraints!(table, known_temporaries, except: temporary_name)
      remove_check_constraint table, name: constraint_name
      execute "ALTER TABLE #{connection.quote_table_name(table)} RENAME CONSTRAINT " \
              "#{connection.quote_column_name(temporary_name)} TO #{connection.quote_column_name(constraint_name)}"
    end
  rescue ActiveRecord::StatementInvalid => e
    if e.cause.is_a?(PG::CheckViolation) && connection.check_constraints(table).any? { |constraint| constraint.name == constraint_name }
      with_lock_timeout do
        remove_check_constraint table, name: temporary_name if connection.check_constraint_exists?(table, name: temporary_name)
      end
    end
    raise
  end

  def remove_known_temporary_constraints!(table, known_temporaries, except: nil)
    known_temporaries.each do |name, expected_sources|
      next if name == except

      constraint = connection.check_constraints(table).find { |candidate| candidate.name == name }
      next unless constraint
      raise "Unexpected temporary source constraint #{name} on #{table}" unless source_values(constraint) == expected_sources.sort

      remove_check_constraint table, name: name
    end
  end

  def source_values(constraint)
    constraint.expression.scan(/'([^']+)'/).flatten.sort
  end

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      yield
    end
  end
end
