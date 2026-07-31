# frozen_string_literal: true

require "combine_pdf"
require "prawn"
require "prawn/table"

# Builds one quarterly preparation packet: a Cornerstone reconciliation cover
# followed by draft government forms generated from the same report.
class QuarterlyCompliancePacketPdfGenerator
  attr_reader :filename

  def initialize(report)
    @report = report.to_h.deep_symbolize_keys
    @filename = "quarterly_compliance_review_packet_draft_#{meta[:year]}_q#{meta[:quarter]}.pdf"
  end

  def generate
    packet = CombinePDF.new
    packet << CombinePDF.parse(summary_pdf)
    packet << CombinePDF.parse(QuarterlyComplianceOfficialForms::Form941.new(report: @report).generate)
    if @report.dig(:federal_941, :deposit_schedule, :schedule_b_required)
      packet << CombinePDF.parse(QuarterlyComplianceOfficialForms::ScheduleB.new(report: @report).generate)
    end
    packet << CombinePDF.parse(QuarterlyComplianceOfficialForms::W1.new(report: @report).generate)
    packet << CombinePDF.parse(QuarterlyComplianceOfficialForms::Sw2.new(report: @report).generate)
    packet.to_pdf
  end

  private

  def meta
    @report.fetch(:meta)
  end

  def summary_pdf
    pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 40, 42, 46, 42 ])
    pdf.fill_color "1E3A5F"
    pdf.fill_rectangle [ pdf.bounds.left, pdf.bounds.top ], pdf.bounds.width, 72
    pdf.fill_color "FFFFFF"
    pdf.bounding_box([ pdf.bounds.left + 14, pdf.bounds.top - 14 ], width: pdf.bounds.width - 28) do
      pdf.font_size(20) { pdf.text "Quarterly Compliance Packet", style: :bold }
      pdf.font_size(10) { pdf.text "#{meta[:company_name]} — #{meta[:quarter_label]}" }
    end
    pdf.fill_color "172033"
    pdf.move_down 88

    pdf.fill_color "B42318"
    pdf.stroke_color "F04438"
    pdf.fill_and_stroke_rounded_rectangle [ pdf.bounds.left, pdf.cursor ], pdf.bounds.width, 38, 6
    pdf.fill_color "FFFFFF"
    pdf.bounding_box([ pdf.bounds.left + 12, pdf.cursor - 9 ], width: pdf.bounds.width - 24, height: 24) do
      pdf.font_size(12) { pdf.text "DRAFT — NOT FILED", style: :bold, align: :center }
      pdf.font_size(7.5) { pdf.text "Preparation copy only. This packet is not proof of submission, payment, or agency acceptance.", align: :center }
    end
    pdf.move_down 52
    pdf.fill_color "172033"

    pdf.font_size(12) { pdf.text "Packet overview", style: :bold }
    pdf.move_down 6
    overview = [
      [ "Reporting basis", meta[:period_basis] ],
      [ "Quarter", "#{meta[:quarter_start]} through #{meta[:quarter_end]}" ],
      [ "Official due date", @report.dig(:due_dates, :official_due_date) ],
      [ "Internal target", @report.dig(:due_dates, :internal_target_date) ],
      [ "Pay periods included", meta[:pay_periods_included] ],
      [ "Form 500 / W-1 withholding", money(@report.dig(:w1, :total_guam_withholding)) ],
      [ "SWICA wages", money(@report.dig(:swica, :totals, :total_wages)) ],
      [ "Federal 941 liability", money(@report.dig(:federal_941, :report, :lines, :line12_total_after_credits)) ]
    ]
    pdf.table(overview, width: pdf.bounds.width, cell_style: { padding: 6, size: 9, border_color: "CBD5E1" }) do
      column(0).background_color = "EAF1F8"
      column(0).font_style = :bold
    end
    pdf.move_down 18

    pdf.font_size(12) { pdf.text "Reconciliation checks", style: :bold }
    pdf.move_down 6
    checks = Array(@report[:review_checks])
    check_rows = [ [ "Check", "Status", "Result" ] ] +
      checks.map { |check| [ check[:key].to_s.humanize, check[:status].to_s.humanize, check[:message] ] }
    pdf.table(check_rows, width: pdf.bounds.width, header: true, cell_style: {
      padding: 5, size: 8, border_color: "CBD5E1", overflow: :shrink_to_fit
    }) { row(0).background_color = "EAF1F8"; row(0).font_style = :bold }
    pdf.move_down 16

    pdf.fill_color "607089"
    pdf.font_size(8) do
      pdf.text "The following pages are draft Form 941#{' and Schedule B' if @report.dig(:federal_941, :deposit_schedule, :schedule_b_required)}, Guam W-1, and Guam SW-2/SWICA preparation copies generated from the same committed payroll data. Review all fields and file through the appropriate agency channel."
    end
    pdf.render
  end

  def money(value)
    format("$%.2f", value.to_f)
  end
end
