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
  belongs_to :organization
  belongs_to :invoice_recipient
  belongs_to :invoice_billing_profile
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :line_items,
           -> { order(:position, :id) },
           class_name: "InvoiceLineItem",
           dependent: :destroy,
           inverse_of: :invoice

  accepts_nested_attributes_for :line_items, allow_destroy: true

  before_validation :normalize_blanks
  before_validation :default_organization_from_company
  before_validation :default_billing_profile
  before_validation :assign_invoice_number, on: :create
  before_validation :sync_total_amount

  validates :invoice_number, presence: true, uniqueness: { scope: :invoice_billing_profile_id }
  validates :invoice_date, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :recipient_must_belong_to_organization
  validate :billing_profile_must_belong_to_organization
  validate :company_must_belong_to_organization
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

  SNAPSHOT_VERSION = 1

  def mark_generated!(actor:, snapshot: nil)
    snapshot_payload = snapshot.presence || generated_snapshot(actor: actor)
    update!(
      status: "generated",
      generated_at: snapshot_payload["generated_at"],
      updated_by: actor,
      snapshot: snapshot_payload,
      snapshot_version: SNAPSHOT_VERSION
    )
  end

  def draft_snapshot(actor: nil)
    build_snapshot(actor: actor)
  end

  def generated_snapshot(actor:)
    build_snapshot(actor: actor, status: "generated")
  end

  def update_status!(next_status, actor:)
    next_status = next_status.to_s
    unless ALLOWED_TRANSITIONS.fetch(status, []).include?(next_status)
      errors.add(:status, "cannot transition from #{status} to #{next_status}")
      raise ActiveRecord::RecordInvalid, self
    end

    case next_status
    when "draft"
      update!(
        status: "draft",
        generated_at: nil,
        sent_at: nil,
        paid_at: nil,
        voided_at: nil,
        archived_at: nil,
        updated_by: actor,
        snapshot: {}
      )
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
    return unless invoice_billing_profile&.persisted?

    invoice_billing_profile.with_lock do
      prefix = invoice_billing_profile.invoice_prefix.presence || invoice_recipient&.invoice_prefix.presence || "INV"
      next_number = self.class.where(invoice_billing_profile_id: invoice_billing_profile_id).count + 1

      loop do
        candidate = "#{prefix}-#{Time.current.year}-#{next_number.to_s.rjust(4, '0')}"
        unless self.class.exists?(invoice_billing_profile_id: invoice_billing_profile_id, invoice_number: candidate)
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

  def default_organization_from_company
    self.organization ||= company&.organization
  end

  def default_billing_profile
    return if invoice_billing_profile.present? || organization.blank?

    self.invoice_billing_profile = InvoiceBillingProfile.ensure_default_for!(organization)
  end

  def recipient_must_belong_to_organization
    return if invoice_recipient.blank? || organization_id.blank?
    return if invoice_recipient.organization_id == organization_id

    errors.add(:invoice_recipient, "must belong to the same organization")
  end

  def billing_profile_must_belong_to_organization
    return if invoice_billing_profile.blank? || organization_id.blank?
    return if invoice_billing_profile.organization_id == organization_id

    errors.add(:invoice_billing_profile, "must belong to the same organization")
  end

  def company_must_belong_to_organization
    return if company.blank? || organization_id.blank?
    return if company.organization_id == organization_id

    errors.add(:company, "must belong to the same organization")
  end

  def finalized_status?
    generated_or_later?
  end

  def must_have_line_items
    return if line_items.reject(&:marked_for_destruction?).any?

    errors.add(:line_items, "must include at least one line item")
  end

  def build_snapshot(actor:, status: self.status, generated_at: Time.current)
    {
      "version" => SNAPSHOT_VERSION,
      "generated_at" => generated_at.iso8601,
      "generated_by" => actor && { "id" => actor.id, "name" => actor.name, "email" => actor.email },
      "invoice" => {
        "id" => id,
        "invoice_number" => invoice_number,
        "invoice_date" => invoice_date&.iso8601,
        "service_period_start" => service_period_start&.iso8601,
        "service_period_end" => service_period_end&.iso8601,
        "status" => status,
        "payment_terms" => payment_terms,
        "notes" => notes,
        "email_subject" => email_subject,
        "email_body" => email_body,
        "total_amount" => total_amount.to_s
      },
      "billing_profile" => billing_profile_snapshot,
      "recipient" => recipient_snapshot,
      "line_items" => line_items.reject(&:marked_for_destruction?).sort_by { |item| [ item.position.to_i, item.id.to_i ] }.map do |item|
        {
          "description" => item.description,
          "quantity" => item.quantity.to_s,
          "rate" => item.rate.to_s,
          "amount" => item.amount.to_s,
          "service_date" => item.service_date&.iso8601,
          "position" => item.position
        }
      end
    }
  end

  def billing_profile_snapshot
    profile = invoice_billing_profile
    {
      "id" => profile&.id,
      "name" => profile&.name,
      "legal_name" => profile&.legal_name,
      "website" => profile&.website,
      "phone" => profile&.phone,
      "email" => profile&.email,
      "address" => profile&.address,
      "payment_instructions" => profile&.payment_instructions,
      "default_payment_terms" => profile&.default_payment_terms,
      "remit_to" => profile&.remit_to,
      "footer_note" => profile&.footer_note
    }
  end

  def recipient_snapshot
    recipient = invoice_recipient
    {
      "id" => recipient&.id,
      "name" => recipient&.name,
      "email" => recipient&.email,
      "address" => recipient&.address,
      "payment_terms" => recipient&.payment_terms
    }
  end
end
