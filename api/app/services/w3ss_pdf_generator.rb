# frozen_string_literal: true

# Records copy of the IRS 2026 W-3SS. Never a paper filing substitute.
class W3ssPdfGenerator < OfficialPdfOverlay
  def initialize(company:, report:, draft:)
    @company, @report, @draft = company, report, draft
    raise ArgumentError, "W-3SS template supports 2026 only" unless report.dig(:meta, :year).to_i == 2026

    super(template_path: Rails.root.join("lib/assets/fw3ss.pdf"), page_sizes: [ [ 612, 792 ] ])
  end

  private

  def load_template!
    source = super
    CombinePDF.new.tap { |pdf| pdf << source.pages.fetch(2) }
  end

  def draw_page(pdf, _page_number)
    c = @company
    totals = @report.fetch(:totals)
    draw_text_box(pdf, [ 36, 648, 153, 660 ], @report[:employees].length)
    draw_text_box(pdf, [ 156, 648, 264, 660 ], c.establishment_number)
    draw_text_box(pdf, [ 36, 624, 264, 636 ], c.ein)
    draw_text_box(pdf, [ 36, 604, 264, 616 ], c.name)
    draw_text_box(pdf, [ 36, 532, 264, 578 ], c.full_address)
    Efw2W2GuGenerator::BOXES.each_with_index do |box, index|
      row = index / 2
      left = index.even? ? 268 : 426
      draw_text_box(pdf, [ left, 648 - row * 24, left + 148, 660 - row * 24 ], money_string(totals.fetch(box)), align: :right)
    end
    draw_text_box(pdf, [ 426, 528, 574, 540 ], money_string(totals[:box12_code_d_total].to_d + totals[:box12_code_aa_total].to_d), align: :right)
    draw_checkbox(pdf, [ { "R" => 124, "M" => 160, "A" => 196, "F" => 232, "H" => 160, "Q" => 196 }.fetch(c.employment_code), c.employment_code.in?(%w[H Q]) ? 674 : 698, 250, 710 ], true)
    draw_checkbox(pdf, [ { "N" => 369, "T" => 420, "S" => 369, "Y" => 420, "F" => 478 }.fetch(c.kind_of_employer), c.kind_of_employer.in?(%w[N T]) ? 698 : 674, 500, 710 ], true)
    draw_text_box(pdf, [ 36, 432, 264, 444 ], c.filing_contact_name)
    draw_text_box(pdf, [ 268, 432, 420, 444 ], c.phone)
    draw_text_box(pdf, [ 268, 408, 574, 420 ], c.email)
  end

  def draw_document_status(pdf, _page_number)
    draw_text_box(pdf, [ 36, 762, 576, 786 ], "#{@draft ? 'DRAFT — ' : ''}For your records — do not mail when you e-file", size: 11, align: :center)
  end
end
