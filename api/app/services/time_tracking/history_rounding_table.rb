# frozen_string_literal: true

module TimeTracking
  class HistoryRoundingTable
    def self.render(rows)
      headings = %w[Employee Run Component Category Source Paid Paid-minus-source Reviewed]
      cells = rows.map do |row|
        [ row.fetch("employee_id"), row.fetch("run_id"), row["earning_component"] || "aggregate",
          row.fetch("category"), row.fetch("source_total"), row.fetch("paid_total"),
          row.fetch("signed_difference"), row.fetch("acknowledged") ? "yes" : "REQUIRED" ]
      end
      ([ headings ] + cells).map { |row| row.map { |value| value.to_s.gsub(/[\r\n\t]/, " ") }.join("\t") }.join("\n")
    end
  end
end
