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
    kinds = lines.map { |line| line["source_kind"] }.uniq
    return unless kinds.one? && kinds.first.in?(%w[current carryover correction])

    dates = lines.map { |line| Date.iso8601(line.fetch("original_work_date")) }.uniq.sort
    return if dates.empty?

    suffix = label.delete_prefix(bucket.fetch("label"))
    category = bucket.fetch("label").sub(/ · [^·]+ (?:carryover from|correction for|current period).*\z/, "")
    return compact ? "#{suffix.strip.presence && "#{suffix.strip}: "}#{category.truncate(28)}" : nil if kinds.first == "current"
    title = kinds.first == "carryover" ? "Prior-period" : "Correction"
    if compact
      # Dates and OT precede the optional category; never truncate provenance.
      "#{title}#{suffix}\n#{date_ranges(dates, '%m/%d/%y')}\n#{category.truncate(28)}"
    else
      "#{title} hours worked #{date_ranges(dates, '%b %-d, %Y')}\n#{category}#{suffix}"
    end
  rescue Date::Error, KeyError
    # Do not invent dates when a legacy record has incomplete source evidence.
    nil
  end

  private

  def buckets
    @buckets ||= begin
      current_entries = []
      captured = @source_items.flat_map do |item|
        entries = Array(item.wage_rate_hours).select { |entry| entry["source_lines"].present? && entry["label"].present? }
        if entries.empty? && (item == @item || item.import_source.to_s.start_with?("time_tracking:"))
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
