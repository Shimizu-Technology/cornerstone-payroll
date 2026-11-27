# frozen_string_literal: true

require "pdf/reader"

module EmployeeDocuments
  # Use the issued statement for legacy revisions. Live payroll cannot tell us
  # what appeared in an earlier revision, especially its YTD columns.
  module PrintedFigures
    class Unreadable < StandardError; end

    SECTIONS = [ "EARNINGS", "DEDUCTIONS", "SUMMARY", "NON-TAXABLE ADDITIONS",
      "EMPLOYER CONTRIBUTIONS", "YEAR-TO-DATE SUMMARY" ].freeze
    AMOUNT = /-?\$[\d,]+\.\d{2}(?:\/yr)?/
    VALUES = /\s+((?:—|-?[\d,]+\.\d{2}|#{AMOUNT})(?:\s+(?:—|-?[\d,]+\.\d{2}|#{AMOUNT}))*)\z/

    module_function

    Digests = Data.define(:full, :current) do
      def attributes
        { printed_figures_sha256: full, current_figures_sha256: current }
      end
    end

    def for_document(document)
      if document.printed_figures_sha256 && document.current_figures_sha256
        return Digests.new(full: document.printed_figures_sha256, current: document.current_figures_sha256)
      end

      bytes = R2StorageService.new.download(document.storage_key)
      raise Unreadable unless bytes && Digest::SHA256.hexdigest(bytes) == document.sha256

      digest(bytes)
    end

    def digest(bytes)
      section = nil
      figures = Hash.new { |hash, key| hash[key] = [] }
      pdf = PDF::Reader.new(StringIO.new(bytes))
      pdf.pages.each do |page|
        rows(page).each do |line|
          # The current summary starts with a two-cell table heading.
          if line.match?(/\ASUMMARY\s+Current\z/)
            section = "SUMMARY"
          elsif SECTIONS.include?(line)
            section = line
          elsif section && (values = line[VALUES, 1]) && values.match?(AMOUNT)
            figures[section] << values.split.map { |value| value.delete(",") }
          end
        end
      end
      raise Unreadable unless %w[EARNINGS SUMMARY].all? { |heading| figures[heading].any? }

      current = figures.except("YEAR-TO-DATE SUMMARY").filter_map do |heading, entries|
        values = if heading == "SUMMARY"
          entries
        else
          # The last cell is YTD. Ignore rows that exist solely to display
          # earlier pay, while retaining rows with current hours or amounts.
          entries.map { |entry| entry.size == 1 ? entry : entry[0...-1] }.select do |entry|
            entry.any? { |value| value.delete("$").to_d.nonzero? }
          end
        end
        [ heading, values ] if values.any?
      end
      Digests.new(full: Digest::SHA256.hexdigest(figures.sort.to_json),
        current: Digest::SHA256.hexdigest(current.sort.to_json))
    rescue PDF::Reader::Error, ArgumentError => error
      raise Unreadable, error.class.name
    end

    def rows(page)
      # Group glyphs by baseline, excluding oversized watermarks. Page#text
      # uses a grid whose spacing can collapse adjacent table rows.
      page.runs(merge: false).select { |run| run.font_size < 20 }
        .group_by { |run| run.y.round }.sort_by { |y, _| -y }.map do |_, row|
        line = +""
        previous = nil
        row.sort_by(&:x).each do |run|
          line << " " if previous && run.x - (previous.x + previous.width) > run.font_size * 0.2
          line << run.text
          previous = run
        end
        line.strip
      end
    end
  end
end
