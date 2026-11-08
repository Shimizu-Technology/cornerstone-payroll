# frozen_string_literal: true

# Presentation only: captured labels are part of the immutable earnings proof.
# Never replace the stored label or use the display label as a YTD grouping key.
class PayrollSourceEarningLabel
  def initialize(item, source_items: [])
    @item = item
    @source_items = [ item, *source_items ].uniq
  end

  def call(label, compact: false)
    bucket = buckets.find { |entry| label == entry["label"] || %w[OT Holiday PTO].any? { |kind| label == "#{entry['label']} #{kind}" } }
    return unless bucket

    lines = Array(bucket["source_lines"])
    groups = lines.group_by { |line| line["source_kind"] }
    return if groups.empty? || (groups.keys - %w[current carryover correction]).any?

    suffix = label.delete_prefix(bucket.fetch("label"))
    category = bucket.fetch("label").sub(/ · [^·]+ (?:carryover from|correction for|current period).*\z/, "")
    return compact ? "#{suffix.strip.presence && "#{suffix.strip}: "}#{category.truncate(28)}" : nil if groups.keys == [ "current" ]
    titles = { "current" => "Current-period", "carryover" => "Prior-period", "correction" => "Correction" }
    provenance = %w[current carryover correction].filter_map do |kind|
      next unless groups[kind]

      dates = groups.fetch(kind).map { |line| Date.iso8601(line.fetch("original_work_date")) }.uniq.sort
      if compact
        "#{titles.fetch(kind)}#{suffix}\n#{date_ranges(dates, '%m/%d/%y')}"
      else
        "#{titles.fetch(kind)} hours worked #{date_ranges(dates, '%b %-d, %Y')}"
      end
    end.join("\n")
    # Keep the financial row intact, but identify each kind's work dates.
    compact ? "#{provenance}\n#{category.truncate(28)}" : "#{provenance}\n#{category}#{suffix}"
  rescue Date::Error, KeyError
    # Do not invent dates when a legacy record has incomplete source evidence.
    nil
  end

  private

  def buckets
    @buckets ||= begin
      current_entries = []
      captured_by_item = @source_items.to_h do |item|
        [ item, Array(item.wage_rate_hours).select { |entry| entry["source_lines"].present? && entry["label"].present? } ]
      end
      fallback_items = @source_items.select do |item|
        captured_by_item.fetch(item).empty? && (item == @item || item.import_source.to_s.start_with?("time_tracking:"))
      end
      # A year-end batch must not query allocations once per historical check.
      ActiveRecord::Associations::Preloader.new(records: fallback_items.grep(PayrollItem), associations: :time_tracking_entry_allocations).call
      captured = @source_items.flat_map do |item|
        entries = captured_by_item.fetch(item)
        if fallback_items.include?(item)
          entries = item.time_tracking_entry_allocations.map(&:earning_snapshot)
            .select { |entry| entry["source_lines"].present? && entry["label"].present? }
        end
        current_entries = entries if item == @item
        entries
      end
      captured.group_by { |entry| entry["label"] }.values.map do |entries|
        # A stored label can encode a range with gaps. Historical work within
        # that range must not be presented as work paid on the current check.
        current = current_entries.select { |entry| entry["label"] == entries.first["label"] }
        entries = current if current.any?
        entries.first.merge("source_lines" => entries.flat_map { |entry| entry["source_lines"] }.uniq)
      end.sort_by { |entry| -entry["label"].length }
    end
  end

  # Preserve gaps and years instead of claiming all work between min/max dates.
  def date_ranges(dates, format)
    dates.slice_when { |left, right| right != left + 1.day }.map do |group|
      group.one? ? group.first.strftime(format) : "#{group.first.strftime(format)}-#{group.last.strftime(format)}"
    end.join(", ")
  end
end
