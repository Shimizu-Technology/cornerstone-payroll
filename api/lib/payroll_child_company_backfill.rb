# frozen_string_literal: true

require_relative "../db/migrate/support/m3_7_child_companies"

class PayrollChildCompanyBackfill
  DEFAULT_BATCH_SIZE = 1_000

  def initialize(connection:, batch_size: DEFAULT_BATCH_SIZE)
    @connection = connection
    @batch_size = Integer(batch_size, exception: false)
    raise ArgumentError, "BATCH_SIZE must be between 1 and 10,000" unless (1..10_000).cover?(@batch_size)
  end

  def backfill
    M3_7ChildCompanies::CHILDREN.each do |table, (key, parent)|
      updated = backfill_table(table, key, parent)
      yield table, updated
    end
  end

  def verify
    @connection.transaction do
      @connection.execute("SET TRANSACTION READ ONLY")
      M3_7ChildCompanies::CHILDREN.each_key do |table|
        nulls = @connection.select_value("SELECT COUNT(*) FROM #{table} WHERE company_id IS NULL")
        fk_state = @connection.select_value(<<~SQL)
          SELECT CASE WHEN convalidated THEN 'valid' ELSE 'not valid' END
          FROM pg_constraint
          WHERE contype = 'f'
            AND conrelid = '#{table}'::regclass
            AND conname = '#{M3_7ChildCompanies.foreign_key_name(table)}'
        SQL
        yield table, nulls, fk_state || "missing"
      end
    end
  end

  private

  def backfill_table(table, key, parent)
    # Each run has a finite range. A retry starts from the beginning and
    # selects only rows still missing company ownership.
    upper_id = @connection.select_value("SELECT MAX(id) FROM #{table}")
    return 0 unless upper_id

    cursor = nil
    updated = 0
    loop do
      after_cursor = "AND id > #{cursor}" if cursor
      cursor, count = @connection.transaction do
        @connection.execute("SET LOCAL lock_timeout = '5s'")
        @connection.exec_query(<<~SQL).rows.first
          WITH batch AS (
            SELECT id FROM #{table}
            WHERE company_id IS NULL AND id <= #{upper_id} #{after_cursor}
            ORDER BY id LIMIT #{@batch_size}
          ), updated AS (
            UPDATE #{table} AS child SET company_id = parent.company_id
            FROM batch, #{parent} AS parent
            WHERE child.id = batch.id AND child.company_id IS NULL
              AND parent.id = child.#{key} AND parent.company_id IS NOT NULL
            RETURNING child.id
          )
          SELECT (SELECT MAX(id) FROM batch), (SELECT COUNT(*) FROM updated)
        SQL
      end
      updated += count
      break unless cursor
    end
    updated
  end
end
