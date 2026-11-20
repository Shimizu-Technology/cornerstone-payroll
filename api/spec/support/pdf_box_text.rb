# frozen_string_literal: true

require "pdf/reader"

# Reads PDF text by where each glyph sits on the page. pdf-reader's
# Page#text lays text onto a character grid sized from the page's mean font
# size, so a large watermark can merge two rows and overwrite one with the
# other. These helpers group glyphs by baseline instead.
module PdfBoxText
  # Anything larger is a watermark, not form content.
  MAX_FONT_SIZE = 20

  # The page's text as rows, top to bottom, each row's glyphs left to right.
  def pdf_rows(page)
    rows(page.runs(merge: false).select { |run| run.font_size < MAX_FONT_SIZE })
  end

  # The text whose baseline lies inside rect [left, bottom, right, top].
  def text_in_box(page, rect)
    left, bottom, right, top = rect
    inside = page.runs(merge: false).select do |run|
      run.font_size < MAX_FONT_SIZE &&
        run.x >= left - 0.5 && run.x + run.width <= right + 0.5 &&
        run.y >= bottom - 0.5 && run.y <= top + 0.5
    end
    rows(inside).join("\n")
  end

  # rect moved down by dy points, for the bottom form on a page.
  def shift_rect(rect, dy)
    left, bottom, right, top = rect
    [ left, bottom - dy, right, top - dy ]
  end

  private

  def rows(runs)
    runs.group_by { |run| run.y.round }.sort_by { |y, _| -y }.map do |_, row|
      line = +""
      previous = nil
      row.sort_by(&:x).each do |run|
        line << " " if previous && run.x - (previous.x + previous.width) > run.font_size * 0.2
        line << run.text
        previous = run
      end
      line
    end
  end
end

RSpec.configure do |config|
  config.include PdfBoxText
end
