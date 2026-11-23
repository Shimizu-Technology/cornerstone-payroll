# frozen_string_literal: true

require_relative "support/m3_7_child_companies"

class IndexPayrollChildCompanies < ActiveRecord::Migration[8.1]
  include M3_7ChildCompanies
  disable_ddl_transaction!

  # These three parents already have a unique (id, company_id) index.
  PARENTS_REQUIRING_INDEX = (PARENTS - %i[employees pay_periods payroll_submissions]).freeze

  def up
    with_session_lock_timeout do
      PARENTS_REQUIRING_INDEX.each { |parent| build_index(parent, %i[id company_id], unique: true) }
      CHILDREN.each do |table, (key, _)|
        build_index(table, [ :company_id, key ])
      end
    end
  end

  def down
    with_session_lock_timeout do
      CHILDREN.each { |table, (key, _)| drop_index(table, [ :company_id, key ]) }
      PARENTS_REQUIRING_INDEX.each { |parent| drop_index(parent, %i[id company_id]) }
    end
  end

  private

  def with_session_lock_timeout
    previous_timeout = select_value("SHOW lock_timeout")
    execute "SET lock_timeout = '5s'"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_timeout)}" if previous_timeout
  end

  def build_index(table, columns, unique: false)
    # Concurrent builds can leave an invalid index after a lock timeout.
    name = connection.index_name(table, column: columns)
    if index_exists?(table, name: name, valid: false)
      remove_index table, name: name, algorithm: :concurrently
    end
    add_index table, columns, name: name, unique: unique, algorithm: :concurrently, if_not_exists: true
  end

  def drop_index(table, columns)
    remove_index table, name: connection.index_name(table, column: columns), algorithm: :concurrently, if_exists: true
  end
end
