# frozen_string_literal: true

require "digest"

class PayrollCompanySetupReview
  ACKNOWLEDGEMENT = "COMPANY SETUP REVIEWED"
  PROFILE_FIELDS = %w[
    name ein address_line1 address_line2 city state zip phone email bank_name bank_address
    pay_frequency check_stock_type next_check_number
  ].freeze
  SECTIONS = [
    {
      key: "legal_employer",
      label: "Legal employer",
      description: "Confirm the legal business name and EIN used on payroll filings.",
      fields: %w[name ein],
      required: %w[name ein]
    },
    {
      key: "filing_address",
      label: "Filing address",
      description: "Confirm the employer address used on checks and government filings.",
      fields: %w[address_line1 address_line2 city state zip],
      required: %w[address_line1 city state zip]
    },
    {
      key: "payroll_contact",
      label: "Payroll contact",
      description: "Confirm where Cornerstone should send payroll questions and completed records.",
      fields: %w[phone email],
      required: []
    },
    {
      key: "payment_defaults",
      label: "Payment defaults",
      description: "Confirm payroll frequency, bank reference, check stock, and next check number.",
      fields: %w[pay_frequency bank_name bank_address check_stock_type next_check_number],
      required: %w[pay_frequency check_stock_type next_check_number]
    }
  ].freeze

  def initialize(review)
    @review = review
  end

  def state
    missing = missing_required_fields
    {
      status: status(missing),
      current: reviewed_current?,
      missing_required_fields: missing,
      sections: sections,
      reviewed_at: review.company_setup_reviewed_at,
      reviewed_by_name: review.company_setup_reviewed_by&.name,
      review_notes: review.company_setup_review_notes,
      acknowledgement: ACKNOWLEDGEMENT
    }
  end

  def confirm!(actor:, acknowledgement:, notes:)
    authorize!(actor)
    raise ArgumentError, "Approved go-live evidence is sealed" if review.approved?
    raise ArgumentError, "Apply the predecessor setup before reviewing the successor company" unless review.setup_applied?
    raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT

    normalized_notes = notes.to_s.squish
    raise ArgumentError, "Document what was checked and any remaining operational follow-up" if normalized_notes.blank?
    raise ArgumentError, "Company setup review notes are too long" if normalized_notes.length > 2_000

    missing = missing_required_fields
    if missing.any?
      raise ArgumentError, "Complete the required company fields first: #{missing.map { |field| field_label(field) }.join(', ')}"
    end

    review.update!(
      company_setup_digest: digest,
      company_setup_review_notes: normalized_notes,
      company_setup_reviewed_at: Time.current,
      company_setup_reviewed_by: actor,
      technical_signed_by: nil,
      technical_signed_at: nil,
      operations_signed_by: nil,
      operations_signed_at: nil
    )
    audit!(actor)
    review
  end

  def reviewed_current?
    review.company_setup_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(review.company_setup_digest, digest)
  end

  def missing_required_fields
    required_fields.select { |field| review.company.public_send(field).blank? }
  end

  private

  attr_reader :review

  def company
    review.company
  end

  def required_fields
    @required_fields ||= SECTIONS.flat_map { |section| section.fetch(:required) }.uniq
  end

  def sections
    SECTIONS.map do |section|
      fields = section.fetch(:fields).index_with { |field| present?(company.public_send(field)) }
      missing_required = section.fetch(:required).reject { |field| fields.fetch(field) }
      {
        key: section.fetch(:key),
        label: section.fetch(:label),
        description: section.fetch(:description),
        fields: fields,
        missing_required_fields: missing_required,
        complete: missing_required.empty?
      }
    end
  end

  def status(missing)
    return "missing_required" if missing.any?
    return "current" if reviewed_current?
    return "stale" if review.company_setup_digest.present?

    "needs_review"
  end

  def digest
    values = PROFILE_FIELDS.index_with { |field| company.public_send(field) }
    Digest::SHA256.hexdigest(JSON.generate(values))
  end

  def present?(value)
    value.present? || value == false || value == 0
  end

  def field_label(field)
    field.to_s.humanize.sub("Ein", "EIN")
  end

  def authorize!(actor)
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(company.id) &&
      StaffRolePolicy.allowed?(actor, :payroll_operations)
    raise ArgumentError, "Cornerstone payroll access is required" unless allowed
  end

  def audit!(actor)
    AuditLog.record!(
      user: actor,
      organization_id: company.organization_id,
      company_id: company.id,
      action: "payroll_go_live#review_company_setup",
      record_type: "payroll_go_live_reviews",
      record_id: review.id,
      subject_name: company.name,
      metadata: {
        company_setup_digest: review.company_setup_digest,
        reviewed_fields: PROFILE_FIELDS,
        review_notes: review.company_setup_review_notes
      }
    )
  end
end
