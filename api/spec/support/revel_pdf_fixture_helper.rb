# frozen_string_literal: true

module RevelPdfFixtureHelper
  REVEL_HEADER = [
    "Employee".ljust(40),
    "Role".ljust(20),
    "Ext. ID".ljust(20),
    "Wage".ljust(20),
    "Regular h.".ljust(20),
    "Overtime h.".ljust(20),
    "Doubletime h.".ljust(20),
    "Regular".ljust(20),
    "Overtime".ljust(20),
    "Doubletime".ljust(20),
    "Total Hours".ljust(20),
    "Total".ljust(20),
    "Fees".ljust(20)
  ].join.freeze

  def build_revel_pdf(rows, period_start: nil, period_end: nil, reported_total_hours: nil)
    fixture = Tempfile.new([ "deidentified-revel-payroll", ".pdf" ])
    fixture.close

    Prawn::Document.generate(fixture.path, page_size: [ 1_000, 700 ], margin: 20) do |pdf|
      pdf.font("Courier")
      pdf.text("Synthetic payroll fixture — no production data", size: 6)
      if period_start && period_end
        pdf.text("Payroll period: #{period_start.iso8601} to #{period_end.iso8601}", size: 6)
      end
      pdf.move_down(4)
      pdf.text(REVEL_HEADER, size: 4)
      rows.each do |row|
        name = row.fetch(:name)
        if name.include?("\n")
          first_line, name = name.split("\n", 2)
          pdf.text(first_line, size: 4)
        end
        row = row.merge(name: name)
        text = block_given? ? yield(row) : revel_row(**row)
        pdf.text(text, size: 4)
      end
      total_hours = reported_total_hours || rows.sum { |row| row.fetch(:total_hours, row.fetch(:regular_hours)) }
      total_pay = rows.sum { |row| row.fetch(:total_pay, row.fetch(:regular_pay)) }
      pdf.text("Totals".ljust(220) + decimal_field(total_hours) + decimal_field(total_pay), size: 4)
    end

    revel_fixture_tempfiles << fixture
    fixture.path
  end

  def revel_row(name:, regular_hours:, regular_pay:, overtime_hours: 0.0, overtime_pay: 0.0,
                doubletime_hours: nil, doubletime_pay: nil, total_hours: nil, total_pay: nil)
    total_hours ||= regular_hours + overtime_hours + (doubletime_hours || 0)
    total_pay ||= regular_pay + overtime_pay + (doubletime_pay || 0)

    [
      name.ljust(40),
      "-".ljust(20),
      "-".ljust(20),
      "-".ljust(20),
      decimal_field(regular_hours),
      decimal_field(overtime_hours),
      doubletime_hours.nil? ? "-".ljust(20) : decimal_field(doubletime_hours),
      decimal_field(regular_pay),
      decimal_field(overtime_pay),
      doubletime_pay.nil? ? "-".ljust(20) : decimal_field(doubletime_pay),
      decimal_field(total_hours),
      decimal_field(total_pay),
      "-".ljust(20)
    ].join
  end

  def revel_fixture_tempfiles
    @revel_fixture_tempfiles ||= []
  end

  def cleanup_revel_pdf_fixtures
    revel_fixture_tempfiles.each do |fixture|
      fixture.close unless fixture.closed?
      fixture.unlink
    rescue Errno::ENOENT
      nil
    end
    revel_fixture_tempfiles.clear
  end

  private

  def decimal_field(value)
    format("%.2f", value).rjust(15).ljust(20)
  end
end

RSpec.configure do |config|
  config.include RevelPdfFixtureHelper
  config.after { cleanup_revel_pdf_fixtures }
end
