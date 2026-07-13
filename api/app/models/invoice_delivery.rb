# frozen_string_literal: true

class InvoiceDelivery < ApplicationRecord
  CHANNELS = %w[email mail hand_delivery portal other].freeze

  belongs_to :organization
  belongs_to :invoice
  belongs_to :invoice_artifact, optional: true
  belongs_to :recorded_by, class_name: "User", optional: true

  validates :channel, inclusion: { in: CHANNELS }
  validates :delivered_at, presence: true
  validate :invoice_must_belong_to_organization
  validate :artifact_must_belong_to_invoice

  scope :chronological, -> { order(:delivered_at, :id) }

  private

  def invoice_must_belong_to_organization
    return if invoice.blank? || organization_id.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def artifact_must_belong_to_invoice
    return if invoice_artifact.blank? || invoice.blank? || invoice_artifact.invoice_id == invoice.id

    errors.add(:invoice_artifact, "must belong to the same invoice")
  end
end
