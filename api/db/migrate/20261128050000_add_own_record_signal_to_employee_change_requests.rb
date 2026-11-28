# frozen_string_literal: true

class AddOwnRecordSignalToEmployeeChangeRequests < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = "employee_change_requests_own_record_signal_check"

  def up
    with_lock_timeout do
      unless column_exists?(:employee_change_requests, :own_record_signal)
        add_column :employee_change_requests, :own_record_signal, :string
      end
    end

    unless check_constraint_exists?(:employee_change_requests, name: CONSTRAINT_NAME)
      with_lock_timeout do
        add_check_constraint(
          :employee_change_requests,
          "own_record_signal IS NULL OR own_record_signal IN ('strong', 'name_only')",
          name: CONSTRAINT_NAME,
          validate: false
        )
      end
    end

    validate_check_constraint :employee_change_requests, name: CONSTRAINT_NAME
  end

  def down
    with_lock_timeout do
      if check_constraint_exists?(:employee_change_requests, name: CONSTRAINT_NAME)
        remove_check_constraint :employee_change_requests, name: CONSTRAINT_NAME
      end
      if column_exists?(:employee_change_requests, :own_record_signal)
        remove_column :employee_change_requests, :own_record_signal
      end
    end
  end

  private

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      yield
    end
  end
end
