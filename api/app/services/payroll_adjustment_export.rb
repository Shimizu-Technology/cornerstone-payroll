# frozen_string_literal: true

# Shapes snapshotted payroll adjustments into dynamic report-export columns.
# It accepts the serialized worker rows used by report payloads so CSV and XLSX
# exports share the same source labels, keys, and aggregation rules.
class PayrollAdjustmentExport
  SOURCE_LABELS = {
    PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE => "employee setup snapshot",
    PayrollItem::MANUAL_ADJUSTMENTS_SOURCE => "manual pay-period entry",
    PayrollAdjustmentDisclosure::LEGACY_SNAPSHOT_SOURCE => "legacy snapshot"
  }.freeze

  attr_reader :workers

  def initialize(workers)
    @workers = Array(workers)
  end

  def columns
    @columns ||= workers.flat_map { |worker| entries_for(worker) }
      .group_by { |entry| key(entry) }
      .map do |entry_key, entries|
        entry = entries.first
        {
          key: entry_key,
          label: entry[:label].to_s,
          treatment: entry[:treatment].to_s,
          source: entry[:source].to_s
        }
      end
      .sort_by { |column| [ treatment_rank(column[:treatment]), column[:label], column[:source] ] }
  end

  def headers
    columns.map { |column| header(column) }
  end

  def values_for(worker)
    columns.map { |column| amount_for(worker, column) }
  end

  def column_totals
    columns.map do |column|
      workers.sum { |worker| amount_for(worker, column).to_f }
    end
  end

  def entries_for(worker)
    Array(worker[:payroll_adjustments]).reject { |entry| entry[:active] == false }
  end

  def grouped_totals
    workers.flat_map { |worker| entries_for(worker) }
      .group_by { |entry| key(entry) }
      .sort_by { |_entry_key, entries| [ entries.first[:treatment].to_s, entries.first[:label].to_s, entries.first[:source].to_s ] }
      .map do |entry_key, entries|
        first = entries.first
        {
          identity: entry_key[0] == :item ? "item:#{entry_key[1]}:#{entry_key[2]}" : "legacy:#{entry_key.join(':')}",
          kind: first[:kind],
          treatment: first[:treatment],
          label: first[:label],
          source: first[:source],
          amount: entries.sum(BigDecimal("0")) { |entry| BigDecimal(entry[:amount].to_s.presence || "0") }
        }
      end
  end

  private

  def header(column)
    source = SOURCE_LABELS.fetch(column[:source], "snapshot")
    identity = column[:key][0] == :item ? "; item ##{column[:key][1]}/#{column[:key][2].to_i + 1}" : ""
    "Payroll Adjustment - #{column[:label]} (#{column[:treatment].humanize}; #{source}#{identity})"
  end

  def amount_for(worker, column)
    matching = entries_for(worker).select { |entry| key(entry) == column[:key] }
    return nil if matching.empty?

    matching.sum { |entry| entry[:amount].to_f }
  end

  def key(entry)
    if entry[:payroll_item_id].present? && !entry[:position].nil?
      [ :item, entry[:payroll_item_id], entry[:position] ]
    else
      [ entry[:label].to_s, entry[:treatment].to_s, entry[:source].to_s ]
    end
  end

  def treatment_rank(treatment)
    PayrollAdjustmentDisclosure::TREATMENTS.index(treatment) || PayrollAdjustmentDisclosure::TREATMENTS.length
  end
end
