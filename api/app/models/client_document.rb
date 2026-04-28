# frozen_string_literal: true

class ClientDocument < ApplicationRecord
  MAX_FILE_SIZE = 25.megabytes
  CATEGORIES = %w[
    payroll_source
    employee_onboarding
    tax_notice
    direct_deposit
    identity
    insurance
    misc
  ].freeze
  ALLOWED_EXTENSIONS = %w[pdf png jpg jpeg webp txt csv doc docx xls xlsx].freeze
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    application/msword
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    image/jpeg
    image/png
    image/webp
    text/plain
    text/csv
  ].freeze
  ORIGINAL_INLINE_PREVIEW_EXTENSIONS = %w[pdf png jpg jpeg webp].freeze
  GENERATED_PREVIEW_EXTENSIONS = %w[doc docx xls xlsx csv txt].freeze
  PREVIEW_STATUSES = %w[pending processing ready failed not_required].freeze

  belongs_to :company
  belongs_to :employee, optional: true
  belongs_to :uploaded_by, class_name: "User", optional: true

  validates :title, :category, :file_name, :file_key, :content_type, presence: true
  validates :uploaded_by, presence: true, on: :create
  validates :category, inclusion: { in: CATEGORIES }
  validates :file_size, numericality: { greater_than: 0 }
  validates :preview_status, inclusion: { in: PREVIEW_STATUSES }

  scope :recent_first, -> { order(created_at: :desc) }

  def self.detected_content_type(file)
    detected = file.content_type.presence
    detected ||= Marcel::MimeType.for(file.tempfile, name: file.original_filename)
    detected.presence || "application/octet-stream"
  rescue StandardError
    file.content_type.presence || "application/octet-stream"
  end

  def self.upload_validation_errors(file)
    errors = []
    return [ "is required" ] unless file.present?

    if file.size.to_i <= 0
      errors << "must not be empty"
    end

    if file.size.to_i > MAX_FILE_SIZE
      errors << "must be 25 MB or smaller"
    end

    extension = File.extname(file.original_filename.to_s).delete(".").downcase
    unless ALLOWED_EXTENSIONS.include?(extension)
      errors << "must be one of: #{ALLOWED_EXTENSIONS.join(', ')}"
    end

    content_type = detected_content_type(file)
    unless ALLOWED_CONTENT_TYPES.include?(content_type)
      errors << "content type #{content_type} is not supported"
    end

    errors
  end

  def download_filename
    file_name.presence || "#{title.parameterize.presence || 'document'}.bin"
  end

  def preview_ready?
    preview_status == "ready" && preview_file_key.present?
  end

  def preview_generation_required?
    GENERATED_PREVIEW_EXTENSIONS.include?(file_extension)
  end

  def preview_served_from_original?
    ORIGINAL_INLINE_PREVIEW_EXTENSIONS.include?(file_extension)
  end

  def preview_available?
    preview_ready? || preview_served_from_original?
  end

  def preview_filename
    return download_filename if preview_served_from_original?

    "#{File.basename(download_filename, ".*")}-preview.pdf"
  end

  def file_extension
    File.extname(file_name.to_s).delete(".").downcase
  end

  def self.initial_preview_status_for(file)
    extension = File.extname(file.original_filename.to_s).delete(".").downcase
    return "not_required" if ORIGINAL_INLINE_PREVIEW_EXTENSIONS.include?(extension)
    return "pending" if GENERATED_PREVIEW_EXTENSIONS.include?(extension)

    "failed"
  end
end
