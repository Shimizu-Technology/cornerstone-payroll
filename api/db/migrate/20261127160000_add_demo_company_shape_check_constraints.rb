# frozen_string_literal: true

# Track B follow-up: mirror Company#demo_shape_is_permanent at the DB layer so
# validation-skipping writes cannot persist invalid fixture keys or test-workspace
# lifecycle timestamps on flagged demo companies.
#
# Uses NOT VALID followed by VALIDATE CONSTRAINT with bounded lock_timeout
# (restored in ensure) so existing traffic is never blocked on a long lock wait.
class AddDemoCompanyShapeCheckConstraints < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"
  LIFECYCLE_CONSTRAINT = "companies_demo_no_test_workspace_lifecycle"
  FIXTURE_KEY_CONSTRAINT = "companies_demo_fixture_key_format"

  def up
    with_lock_timeout do
      unless constraint_exists?(LIFECYCLE_CONSTRAINT)
        add_check_constraint :companies,
                             "NOT demo OR (test_workspace_expires_at IS NULL AND test_workspace_archived_at IS NULL AND test_workspace_sealed_at IS NULL)",
                             name: LIFECYCLE_CONSTRAINT,
                             validate: false
      end

      unless constraint_exists?(FIXTURE_KEY_CONSTRAINT)
        add_check_constraint :companies,
                             "NOT demo OR NOT (test_workspace_manifest ? 'demo_fixture_key') OR COALESCE(test_workspace_manifest ->> 'demo_fixture_key', '') ~ '^[a-z0-9][a-z0-9-]{2,62}$'",
                             name: FIXTURE_KEY_CONSTRAINT,
                             validate: false
      end
    end

    with_session_lock_timeout do
      validate_check_constraint :companies, name: LIFECYCLE_CONSTRAINT
      validate_check_constraint :companies, name: FIXTURE_KEY_CONSTRAINT
    end
  end

  def down
    with_lock_timeout do
      remove_check_constraint :companies, name: FIXTURE_KEY_CONSTRAINT, if_exists: true
      remove_check_constraint :companies, name: LIFECYCLE_CONSTRAINT, if_exists: true
    end
  end

  private

  def constraint_exists?(name)
    check_constraints(:companies).any? { |constraint| constraint.name == name }
  end

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}"
      yield
    end
  end

  def with_session_lock_timeout
    previous = select_value("SHOW lock_timeout")
    execute "SET lock_timeout = #{connection.quote(LOCK_TIMEOUT)}"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous || '0')}"
  end
end
