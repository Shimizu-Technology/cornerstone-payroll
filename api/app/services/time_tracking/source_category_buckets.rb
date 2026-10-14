# frozen_string_literal: true

module TimeTracking
  # One frozen earning dimension per category and source kind, shared by preview
  # and apply so signed component changes survive even when total hours are zero.
  class SourceCategoryBuckets
    def self.call(adjustments)
      buckets = {}
      Array(adjustments).each do |adjustment|
        category = adjustment["category"] || {}
        key = category_bucket_key(adjustment)
        bucket = buckets[key] ||= {
          source_category_id: adjustment["source_category_id"].to_s.presence,
          key: category["key"].to_s.presence,
          name: category["name"].presence || "Uncategorized",
          total_hours: 0.to_d,
          regular_hours: 0.to_d,
          overtime_hours: 0.to_d,
          source_kinds: Set.new,
          source_time_entry_ids: Set.new,
          original_work_dates: Set.new,
          source_lines: []
        }
        bucket[:total_hours] += BigDecimal(adjustment.fetch("total_hours").to_s)
        bucket[:regular_hours] += BigDecimal(adjustment.fetch("regular_hours").to_s)
        bucket[:overtime_hours] += BigDecimal(adjustment.fetch("overtime_hours").to_s)
        bucket[:source_kinds] << adjustment.fetch("source_kind")
        bucket[:source_time_entry_ids] << adjustment.fetch("source_time_entry_id")
        bucket[:original_work_dates] << adjustment.fetch("original_work_date")
        bucket[:source_lines] << adjustment.slice("source_time_entry_id", "line_key", "source_time_entry_version",
          "source_kind", "original_work_date", "total_hours", "regular_hours", "overtime_hours")
      end

      buckets.values.map do |bucket|
        bucket.merge(
          total_hours: number(bucket[:total_hours]),
          hours: number(bucket[:total_hours]),
          regular_hours: number(bucket[:regular_hours]),
          overtime_hours: number(bucket[:overtime_hours]),
          source_kinds: bucket[:source_kinds].to_a.sort,
          source_time_entry_ids: bucket[:source_time_entry_ids].to_a.sort,
          original_work_dates: bucket[:original_work_dates].to_a.sort
        )
      end.sort_by do |bucket|
        [ bucket[:name].to_s, bucket[:key].to_s, bucket[:source_category_id].to_s, bucket[:source_kinds].join(",") ]
      end
    end

    def self.category_bucket_key(adjustment)
      category = adjustment["category"] || {}
      [
        adjustment["source_category_id"],
        category["key"],
        category["name"],
        adjustment["source_kind"]
      ].map(&:to_s).map(&:strip).join("|")
    end

    def self.number(value)
      value.to_d.round(2).to_f
    end

    private_class_method :category_bucket_key, :number
  end
end
