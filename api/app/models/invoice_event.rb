# frozen_string_literal: true

class InvoiceEvent < ApplicationRecord
  belongs_to :organization
  belongs_to :invoice
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, :occurred_at, presence: true
  validate :invoice_must_belong_to_organization

  scope :timeline, -> { order(:occurred_at, :id) }

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def self.record!(invoice:, event_type:, actor: nil, occurred_at: Time.current, metadata: {})
    create!(
      organization: invoice.organization,
      invoice: invoice,
      event_type: event_type,
      actor: actor,
      occurred_at: occurred_at,
      metadata: metadata.presence || {}
    )
  end

  private

  def invoice_must_belong_to_organization
    return if invoice.blank? || organization_id.blank? || invoice.organization_id == organization_id

    errors.add(:invoice, "must belong to the same organization")
  end

  def prevent_mutation
    errors.add(:base, "Invoice events are immutable")
    throw :abort
  end
end
