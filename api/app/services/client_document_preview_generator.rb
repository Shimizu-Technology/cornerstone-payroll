# frozen_string_literal: true

require "fileutils"
require "open3"
require "tempfile"

class ClientDocumentPreviewGenerator
  class GenerationUnavailable < StandardError; end
  class GenerationFailed < StandardError; end

  def initialize(document:, storage: R2StorageService.new)
    @document = document
    @storage = storage
  end

  def generate!
    return unless document.preview_generation_required?

    converter = libreoffice_binary
    raise GenerationUnavailable, "LibreOffice is not installed on this server" if converter.blank?

    Dir.mktmpdir("client-document-preview") do |dir|
      source_path = prepare_source_file(dir)
      output_dir = File.join(dir, "out")
      FileUtils.mkdir_p(output_dir)

      stdout, stderr, status = Open3.capture3(
        converter,
        "--headless",
        "--convert-to",
        "pdf",
        "--outdir",
        output_dir,
        source_path
      )

      unless status.success?
        raise GenerationFailed, [stderr.presence, stdout.presence, "LibreOffice conversion failed"].compact.join("\n")
      end

      pdf_path = Dir[File.join(output_dir, "*.pdf")].first
      raise GenerationFailed, "LibreOffice did not produce a PDF preview" unless pdf_path.present? && File.exist?(pdf_path)

      previous_preview_key = document.preview_file_key
      next_preview_key = build_preview_key(document.file_name)
      File.open(pdf_path, "rb") do |file|
        storage.upload(next_preview_key, file, content_type: "application/pdf")
      end

      begin
        document.update!(
          preview_status: "ready",
          preview_file_key: next_preview_key,
          preview_content_type: "application/pdf",
          preview_generated_at: Time.current,
          preview_error: nil
        )
      rescue StandardError
        cleanup_uploaded_preview!(next_preview_key)
        raise
      end

      delete_previous_preview!(previous_preview_key, replacement_key: next_preview_key)
    end
  rescue R2StorageService::DownloadError, R2StorageService::UploadError => e
    mark_failed!(e.message)
    raise GenerationFailed, e.message
  rescue GenerationUnavailable, GenerationFailed => e
    mark_failed!(e.message)
    raise
  end

  private

  attr_reader :document, :storage

  def prepare_source_file(dir)
    source_path = File.join(dir, safe_source_filename)
    File.binwrite(source_path, storage.download(document.file_key))
    optimize_spreadsheet_layout!(source_path) if spreadsheet_extension?
    source_path
  end

  def spreadsheet_extension?
    %w[csv xlsx].include?(document.file_extension)
  end

  def safe_source_filename
    original_name = document.file_name.to_s
    basename = File.basename(original_name).presence
    return basename if basename.present?

    extension = File.extname(original_name)
    "source#{extension}"
  end

  def optimize_spreadsheet_layout!(source_path)
    stdout, stderr, status = Open3.capture3("python3", "-c", spreadsheet_optimization_script, source_path)
    return if status.success?

    Rails.logger.warn(
      "Spreadsheet preview optimization failed for document #{document.id}: #{[stderr.presence, stdout.presence].compact.join("\n")}"
    )
  rescue StandardError => e
    Rails.logger.warn("Spreadsheet preview optimization errored for document #{document.id}: #{e.message}")
  end

  def delete_previous_preview!(previous_key, replacement_key:)
    return if previous_key.blank? || previous_key == replacement_key

    storage.delete(previous_key)
  rescue R2StorageService::UploadError => e
    Rails.logger.warn("Failed to delete previous preview for document #{document.id}: #{e.message}")
  end

  def cleanup_uploaded_preview!(preview_key)
    return if preview_key.blank?

    storage.delete(preview_key)
  rescue R2StorageService::UploadError => e
    Rails.logger.warn("Failed to clean up uploaded preview for document #{document.id}: #{e.message}")
  end

  def build_preview_key(original_filename)
    base_name = File.basename(original_filename.to_s, ".*").gsub(/[^A-Za-z0-9.\-_]/, "_")
    "client_documents/company_#{document.company_id}/previews/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}_#{base_name}.pdf"
  end

  def libreoffice_binary
    env_binary = ENV["LIBREOFFICE_BIN"]
    return env_binary if env_binary.present? && File.executable?(env_binary)

    @libreoffice_binary ||= begin
      stdout, = Open3.capture2("sh", "-lc", "command -v soffice || command -v libreoffice")
      stdout.to_s.strip.presence
    end
  end

  def mark_failed!(message)
    document.update!(
      preview_status: "failed",
      preview_error: message,
      preview_generated_at: nil,
      preview_file_key: nil,
      preview_content_type: nil
    )
  rescue StandardError => e
    Rails.logger.warn("Failed to persist preview failure state for document #{document.id}: #{e.message}")
  end

  def spreadsheet_optimization_script
    <<~PYTHON
      import csv
      import os
      import sys
      from openpyxl import Workbook, load_workbook
      from openpyxl.worksheet.page import PageMargins, PrintOptions
      from openpyxl.worksheet.properties import PageSetupProperties
      from openpyxl.utils import get_column_letter

      path = sys.argv[1]
      ext = os.path.splitext(path)[1].lower()

      def build_workbook_from_csv(csv_path):
          workbook = Workbook()
          sheet = workbook.active
          with open(csv_path, newline='', encoding='utf-8-sig') as handle:
              for row in csv.reader(handle):
                  sheet.append(row)
          xlsx_path = csv_path + ".xlsx"
          workbook.save(xlsx_path)
          return xlsx_path

      workbook_path = path
      if ext == ".csv":
          workbook_path = build_workbook_from_csv(path)

      workbook = load_workbook(workbook_path)

      def column_usage(sheet):
          highest = 0
          widths = {}
          for row in sheet.iter_rows(values_only=True):
              row_has_values = False
              for idx, value in enumerate(row, start=1):
                  if value is None:
                      continue
                  text = str(value).strip()
                  if not text:
                      continue
                  row_has_values = True
                  highest = max(highest, idx)
                  widths[idx] = max(widths.get(idx, 0), min(len(text), 48))
              if row_has_values:
                  continue
          estimated_total_width = sum(min(max(width + 2, 10), 36) for width in widths.values())
          return highest, widths, estimated_total_width

      for sheet in workbook.worksheets:
          used_columns, widths, estimated_total_width = column_usage(sheet)
          if used_columns == 0:
              used_columns = max(sheet.max_column or 1, 1)

          paper_size = sheet.PAPERSIZE_LETTER
          orientation = sheet.ORIENTATION_PORTRAIT
          fit_to_width = 1

          if used_columns >= 16 or estimated_total_width >= 180:
              paper_size = sheet.PAPERSIZE_TABLOID
              orientation = sheet.ORIENTATION_LANDSCAPE
              fit_to_width = 2
          elif used_columns >= 11 or estimated_total_width >= 120:
              paper_size = sheet.PAPERSIZE_TABLOID
              orientation = sheet.ORIENTATION_LANDSCAPE
          elif used_columns >= 8 or estimated_total_width >= 90:
              paper_size = sheet.PAPERSIZE_LEGAL
              orientation = sheet.ORIENTATION_LANDSCAPE
          elif used_columns >= 6 or estimated_total_width >= 65:
              orientation = sheet.ORIENTATION_LANDSCAPE

          sheet.page_setup.orientation = orientation
          sheet.page_setup.paperSize = paper_size
          sheet.page_setup.fitToWidth = fit_to_width
          sheet.page_setup.fitToHeight = 0
          sheet.sheet_properties.pageSetUpPr = PageSetupProperties(fitToPage=True, autoPageBreaks=False)
          sheet.page_margins = PageMargins(left=0.2, right=0.2, top=0.35, bottom=0.35, header=0.2, footer=0.2)
          sheet.print_options = PrintOptions(horizontalCentered=True, verticalCentered=False)

          for idx in range(1, used_columns + 1):
              letter = get_column_letter(idx)
              dimension = sheet.column_dimensions[letter]
              if dimension.width is None:
                  dimension.width = min(max(widths.get(idx, 10) + 2, 10), 36)

      workbook.save(workbook_path)
    PYTHON
  end
end
