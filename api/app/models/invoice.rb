# frozen_string_literal: true

class Invoice < ApplicationRecord
  STATUSES = %w[draft generated sent paid voided archived].freeze
  ALLOWED_TRANSITIONS = {
    "draft" => %w[generated archived],
    "generated" => %w[draft sent voided archived],
    "sent" => %w[draft paid voided archived],
    "paid" => %w[voided archived],
    "voided" => %w[archived],
    "archived" => []
  }.freeze

  belongs_to :company
  belongs_to :invoice_recipient
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :line_items,
           -> { order(:position, :id) },
           class_name: "InvoiceLineItem",
           dependent: :destroy,
           inverse_of: :invoice

  accepts_nested_attributes_for :line_items, allow_destroy: true

  before_validation :normalize_blanks
  before_validation :assign_invoice_number, on: :create
  before_validation :sync_total_amount

  validates :invoice_number, presence: true, uniqueness: { scope: :company_id }
  validates :invoice_date, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :recipient_must_belong_to_company
  validate :must_have_line_items, if: :finalized_status?

  scope :recent, -> { order(invoice_date: :desc, created_at: :desc) }

  def generated?
    status == "generated"
  end

  def draft?
    status == "draft"
  end

  def sent?
    status == "sent"
  end

  def paid?
    status == "paid"
  end

  def voided?
    status == "voided"
  end

  def archived?
    status == "archived"
  end

  def generated_or_later?
    %w[generated sent paid voided archived].include?(status)
  end

  def mark_generated!(actor:)
    update!(
      status: "generated",
      generated_at: Time.current,
      updated_by: actor
    )
  end

  def update_status!(next_status, actor:)
    next_status = next_status.to_s
    unless ALLOWED_TRANSITIONS.fetch(status, []).include?(next_status)
      errors.add(:status, "cannot transition from #{status} to #{next_status}")
      raise ActiveRecord::RecordInvalid, self
    end

    case next_status
    when "draft"
      update!(status: "draft", generated_at: nil, sent_at: nil, paid_at: nil, voided_at: nil, archived_at: nil, updated_by: actor)
    when "generated"
      mark_generated!(actor: actor)
    when "sent"
      update!(status: "sent", sent_at: Time.current, updated_by: actor)
    when "paid"
      update!(status: "paid", paid_at: Time.current, updated_by: actor)
    when "voided"
      update!(status: "voided", voided_at: Time.current, updated_by: actor)
    when "archived"
      update!(status: "archived", archived_at: Time.current, updated_by: actor)
    else
      errors.add(:status, "is not valid")
      raise ActiveRecord::RecordInvalid, self
    end
  end

  private

  def normalize_blanks
    self.status = status.presence || "draft"
    self.invoice_number = invoice_number.to_s.strip.presence
    self.notes = notes.to_s.strip.presence
    self.payment_terms = payment_terms.to_s.strip.presence
    self.email_subject = email_subject.to_s.strip.presence
    self.email_body = email_body.to_s.strip.presence
  end

  def assign_invoice_number
    return if invoice_number.present?
    return unless company&.persisted?

    company.with_lock do
      prefix = invoice_recipient&.invoice_prefix.presence || "INV"
      next_number = self.class.where(company_id: company_id).count + 1

      loop do
        candidate = "#{prefix}-#{Time.current.year}-#{next_number.to_s.rjust(4, '0')}"
        unless self.class.exists?(company_id: company_id, invoice_number: candidate)
          self.invoice_number = candidate
          break
        end
        next_number += 1
      end
    end
  end

  def sync_total_amount
    self.total_amount = line_items.reject(&:marked_for_destruction?).sum do |item|
      BigDecimal(item.quantity.to_s) * BigDecimal(item.rate.to_s)
    end
  end

  def recipient_must_belong_to_company
    return if invoice_recipient.blank? || company_id.blank?
    return if invoice_recipient.company_id == company_id

    errors.add(:invoice_recipient, "must belong to the same company")
  end

  def finalized_status?
    generated_or_later?
  end

  def must_have_line_items
    return if line_items.reject(&:marked_for_destruction?).any?

    errors.add(:line_items, "must include at least one line item")
  end
end
