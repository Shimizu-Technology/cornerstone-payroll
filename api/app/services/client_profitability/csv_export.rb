# frozen_string_literal: true

require "csv"

module ClientProfitability
  # CSV of a Report: one row per client line, then one row per person on it.
  # Names are neutralized against spreadsheet formulas; numbers stay numbers.
  class CsvExport
    HEADERS = [ "Section", "Client", "Person", "Hours", "Pending hours", "Cost", "Overhead share in cost", "Fees",
                "Tax prep fees", "Other fees", "Margin", "Margin %", "Fees per hour" ].freeze

    def initialize(report)
      @report = report
    end

    def filename
      period = @report.fetch(:period)
      "client-profitability-#{period[:from]}#{period[:from] == period[:through] ? '' : "-to-#{period[:through]}"}.csv"
    end

    def generate
      CSV.generate do |csv|
        csv << [ "Client profitability", text(@report.dig(:period, :label)) ]
        csv << [ "Pending hours costed", @report.dig(:options, :cost_pending) ? "Yes" : "No",
                 "Overhead spread across clients", @report.dig(:options, :spread_overhead) ? "Yes" : "No" ]
        csv << []
        csv << HEADERS
        @report[:clients].each { |line| write_line(csv, "Client", line) }
        write_line(csv, "Internal / overhead#{@report.dig(:overhead, :spread) ? ' (spread across clients)' : ''}", @report[:overhead]) if @report[:overhead]
        @report[:unassigned].each { |line| write_line(csv, line[:kind] == "no_client" ? "No client in Tax" : "Not linked yet", line) }
        @report[:unallocated_costs].each do |entry|
          csv << [ "Pay not matched to hours", text(entry[:name]), "", "", "", entry[:cost], "", "", "", "", "", "", "" ]
        end
        if @report.dig(:unlinked_fees, :fees).to_d.nonzero?
          csv << [ "Fees not linked to a client", "", "", "", "", "", "", @report.dig(:unlinked_fees, :fees),
                   @report.dig(:unlinked_fees, :tax_prep_fees), "", "", "", "" ]
        end
        totals = @report[:totals]
        csv << [ "Total", "", "", totals[:hours], totals[:pending_hours], totals[:cost], "", totals[:fees], totals[:tax_prep_fees],
                 totals[:other_fees], totals[:margin], totals[:margin_percent], totals[:effective_rate] ]
      end
    end

    private

    def write_line(csv, section, line)
      csv << [ section, text(line[:name]), "", line[:hours], line[:pending_hours], line[:cost], line[:overhead_cost], line[:fees],
               line[:tax_prep_fees], line[:other_fees], line[:margin], line[:margin_percent], line[:effective_rate] ]
      line[:people].each do |person|
        csv << [ "Person", text(line[:name]), text(person[:name]), person[:hours], person[:pending_hours], person[:cost],
                 "", "", "", "", "", "", "" ]
      end
    end

    def text(value)
      value = value.to_s
      value.start_with?(*TabularReportCsvExporter::FORMULA_PREFIXES) ? "'#{value.sub(/\A[\t\r]+/, '')}" : value
    end
  end
end
