# frozen_string_literal: true

class InvoiceArtifact < ApplicationRecord
  KINDS = %w[issued_pdf imported_original legacy_snapshot credit_note payment_receipt].freeze

  belongs_to :organization
  belongs_to :invoice
  belongs_to :created_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :storage_key, :filename, :content_type, :sha256, presence: true
  validates :storage_key, uniqueness: true
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :invoice_must_belong_to_organization

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def invoice_must_belong_to_organization
    return if invoice.blank? || organization_id.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def prevent_mutation
    errors.add(:base, "Invoice artifacts are immutable")
    throw :abort
  end
end
