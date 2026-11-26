# frozen_string_literal: true

module Parity
  module Extractors
    # Extracts W-2GU Copy B (top half) and Copy C (bottom half) box amounts and
    # identity fields from official IRS Form W-2GU PDF bytes by exact coordinate
    # rectangles (W2GuOfficialCopies::FIELDS / BOX12) so swapped boxes cannot pass.
    class W2GuPdfExtractor
      include Parity::CanonicalSchema
      include PdfBoxText

      def extract(pdf_bytes)
        reader = PDF::Reader.new(StringIO.new(pdf_bytes))
        page = reader.pages.first
        {
          copy_b: extract_copy(page, dy: 0),
          copy_c: extract_copy(page, dy: W2GuOfficialCopies::HALF_PAGE)
        }
      end

      private

      def extract_copy(page, dy:)
        rect_for = ->(rect) { dy.zero? ? rect : shift_rect(rect, dy) }
        box12_entries = W2GuOfficialCopies::BOX12.each_with_object({}) do |(code_rect, amount_rect), acc|
          code = text_in_box(page, rect_for.call(code_rect)).strip
          amt = money(text_in_box(page, rect_for.call(amount_rect)))
          acc[code] = amt if code.present? && amt
        end

        {
          first_name: text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:first_name])).strip,
          last_name: text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:last_name])).strip,
          suffix: text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:suffix])).strip,
          box1_wages: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box1]))),
          box2_income_tax: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box2]))),
          box3_ss_wages: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box3]))),
          box4_ss_tax: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box4]))),
          box5_medicare_wages: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box5]))),
          box6_medicare_tax: money(text_in_box(page, rect_for.call(W2GuOfficialCopies::FIELDS[:box6]))),
          box12: box12_entries,
          box12_code_d: box12_entries.fetch("D", money(0)),
          box12_code_aa: box12_entries.fetch("AA", money(0))
        }
      end
    end
  end
end
