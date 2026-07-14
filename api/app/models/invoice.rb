# frozen_string_literal: true

class Invoice < ApplicationRecord
  STATUSES = %w[draft open voided uncollectible].freeze
  ORIGINS = %w[native imported].freeze
  SNAPSHOT_VERSION = 2

  belongs_to :company, optional: true
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
  has_many :artifacts, class_name: "InvoiceArtifact", dependent: :restrict_with_error
  has_many :events, -> { timeline }, class_name: "InvoiceEvent", dependent: :restrict_with_error
  has_many :payments, -> { chronological }, class_name: "InvoicePayment", dependent: :restrict_with_error
  has_many :credit_notes, -> { chronological }, class_name: "InvoiceCreditNote", dependent: :restrict_with_error
  has_many :deliveries, -> { chronological }, class_name: "InvoiceDelivery", dependent: :restrict_with_error

  accepts_nested_attributes_for :line_items, allow_destroy: true

  before_validation :normalize_blanks
  before_validation :default_organization_from_company
  before_validation :default_billing_profile
  before_validation :assign_invoice_number, on: :create
  before_validation :sync_total_amount

  validates :invoice_number, presence: true, uniqueness: { scope: :invoice_billing_profile_id }
  validates :invoice_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :origin, inclusion: { in: ORIGINS }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :recipient_must_belong_to_organization
  validate :billing_profile_must_belong_to_organization
  validate :company_must_belong_to_organization
  validate :due_date_cannot_precede_invoice_date
  validate :must_have_line_items, if: :issued?
  validate :issued_financial_content_is_immutable, on: :update

  scope :recent, -> { order(invoice_date: :desc, created_at: :desc) }
  scope :visible, -> { where(archived: false) }
  scope :for_billing_profile, ->(profile_id) { where(invoice_billing_profile_id: profile_id) if profile_id.present? }
  scope :receivables, -> { where(status: %w[open uncollectible]) }

  def draft?
    status == "draft"
  end

  def open?
    status == "open"
  end

  def voided?
    status == "voided"
  end

  def uncollectible?
    status == "uncollectible"
  end

  def issued?
    !draft?
  end

  # Compatibility predicates for older callers while the API/UI moves to issued/open language.
  def generated?
    open?
  end

  def sent?
    deliveries.any? || sent_at.present?
  end

  def paid?
    issued? && total_amount.positive? && balance_due.zero?
  end

  def archived?
    archived
  end

  def generated_or_later?
    issued?
  end

  def active_payments
    payments.reject(&:reversed?)
  end

  def issued_credits
    credit_notes.reject(&:voided?)
  end

  def amount_paid
    active_payments.sum { |payment| BigDecimal(payment.amount.to_s) }
  end

  def credit_total
    issued_credits.sum { |credit| BigDecimal(credit.total_amount.to_s) }
  end

  def balance_due
    [ BigDecimal(total_amount.to_s) - amount_paid - credit_total, BigDecimal("0") ].max
  end

  def reader_status(as_of: Date.current)
    return "draft" if draft?
    return "voided" if voided?
    return "uncollectible" if uncollectible?
    return "paid" if paid?
    return "partially_paid" if amount_paid.positive? || credit_total.positive?
    return "overdue" if due_date.present? && due_date < as_of && balance_due.positive?

    "open"
  end

  def primary_artifact
    artifacts.order(created_at: :desc, id: :desc).find do |artifact|
      artifact.kind.in?(%w[issued_pdf imported_original legacy_snapshot])
    end
  end

  def issue!(actor:, snapshot: nil, issued_at: Time.current)
    raise_invalid_transition!("Only draft invoices can be issued") unless draft?

    snapshot_payload = snapshot.presence || issued_snapshot(actor: actor, issued_at: issued_at)
    update!(
      status: "open",
      issued_at: issued_at,
      generated_at: issued_at,
      updated_by: actor,
      snapshot: snapshot_payload,
      snapshot_version: SNAPSHOT_VERSION
    )
  end

  def mark_generated!(actor:, snapshot: nil)
    issue!(actor: actor, snapshot: snapshot)
  end

  def draft_snapshot(actor: nil)
    build_snapshot(actor: actor)
  end

  def generated_snapshot(actor:)
    issued_snapshot(actor: actor)
  end

  def issued_snapshot(actor:, issued_at: Time.current)
    build_snapshot(actor: actor, status: "open", generated_at: issued_at)
  end

  def void!(actor:, reason:)
    with_lock do
      raise_invalid_transition!("Draft invoices should be deleted instead of voided") if draft?
      raise_invalid_transition!("Paid invoices require payment reversal before voiding") if amount_paid.positive?
      raise_invalid_transition!("Credits applied to this invoice must be voided before it can be voided") if credit_total.positive?
      raise_invalid_transition!("Invoice is already voided") if voided?

      update!(status: "voided", voided_at: Time.current, updated_by: actor)
      InvoiceEvent.record!(invoice: self, event_type: "voided", actor: actor, metadata: { reason: reason })
    end
  end

  def mark_uncollectible!(actor:, reason:)
    with_lock do
      raise_invalid_transition!("Only open invoices can be marked uncollectible") unless open?
      raise_invalid_transition!("Paid invoices cannot be marked uncollectible") if paid?

      update!(status: "uncollectible", updated_by: actor)
      InvoiceEvent.record!(invoice: self, event_type: "marked_uncollectible", actor: actor, metadata: { reason: reason })
    end
  end

  def archive!(actor:)
    with_lock do
      unless archived?
        update!(archived: true, archived_at: Time.current, updated_by: actor)
        InvoiceEvent.record!(invoice: self, event_type: "archived", actor: actor)
      end
    end
    self
  end

  def restore!(actor:)
    with_lock do
      if archived?
        update!(archived: false, archived_at: nil, updated_by: actor)
        InvoiceEvent.record!(invoice: self, event_type: "restored", actor: actor)
      end
    end
    self
  end

  # Backward-compatible action entry point. Paid and sent are evidence-backed actions now.
  def update_status!(next_status, actor:)
    case next_status.to_s
    when "generated", "open"
      issue!(actor: actor)
    when "voided"
      void!(actor: actor, reason: "Status updated by operator")
    when "archived"
      archive!(actor: actor)
    when "uncollectible"
      mark_uncollectible!(actor: actor, reason: "Status updated by operator")
    when "paid"
      raise_invalid_transition!("Record a payment or credit instead of marking an invoice paid")
    when "sent"
      raise_invalid_transition!("Record a delivery instead of changing the financial status")
    when "draft"
      raise_invalid_transition!("Issued invoices cannot return to draft")
    else
      raise_invalid_transition!("Invoice status is not valid")
    end
  end

  private

  def normalize_blanks
    self.status = status.presence || "draft"
    self.origin = origin.presence || "native"
    self.currency = currency.to_s.strip.upcase.presence || "USD"
    self.invoice_number = invoice_number.to_s.strip.presence
    self.customer_reference = customer_reference.to_s.strip.presence
    self.notes = notes.to_s.strip.presence
    self.payment_terms = payment_terms.to_s.strip.presence
    self.email_subject = email_subject.to_s.strip.presence
    self.email_body = email_body.to_s.strip.presence
    self.source_metadata = source_metadata.presence || {}
  end

  def assign_invoice_number
    return if invoice_number.present?
    return unless invoice_billing_profile&.persisted? && invoice_date.present?

    self.invoice_number = InvoiceNumberAllocator.call(
      billing_profile: invoice_billing_profile,
      invoice_date: invoice_date
    )
  end

  def sync_total_amount
    return if origin == "imported" && line_items.empty? && total_amount.present?

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

  def due_date_cannot_precede_invoice_date
    return if due_date.blank? || invoice_date.blank? || due_date >= invoice_date

    errors.add(:due_date, "cannot be before the invoice date")
  end

  def must_have_line_items
    return if line_items.reject(&:marked_for_destruction?).any?

    errors.add(:line_items, "must include at least one line item")
  end

  def issued_financial_content_is_immutable
    return unless status_was.in?(%w[open voided uncollectible])

    protected_changes = changes.keys & %w[
      invoice_billing_profile_id invoice_recipient_id invoice_number invoice_date due_date currency
      customer_reference service_period_start service_period_end total_amount payment_terms snapshot origin
    ]
    return if protected_changes.empty?

    errors.add(:base, "Issued invoice financial content is immutable")
  end

  def raise_invalid_transition!(message)
    errors.add(:status, message)
    raise ActiveRecord::RecordInvalid, self
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
        "due_date" => due_date&.iso8601,
        "currency" => currency,
        "customer_reference" => customer_reference,
        "origin" => origin,
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
