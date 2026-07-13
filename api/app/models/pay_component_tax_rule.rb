# frozen_string_literal: true

class PayComponentTaxRule < ApplicationRecord
  COMPONENT_KINDS = %w[earning deduction employer_contribution].freeze
  TAX_TREATMENTS = %w[taxable exempt reduces_taxable_wages not_applicable].freeze
  OTHER_TREATMENTS = %w[included excluded not_applicable].freeze
  REGISTER_PRESENTATIONS = %w[separate grouped hidden_with_warning].freeze

  belongs_to :company, optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :payroll_liability_entries, dependent: :restrict_with_error

  validates :component_key, :display_name, :component_kind, :fit_treatment,
            :social_security_treatment, :medicare_treatment,
            :additional_medicare_treatment, :swica_treatment,
            :retirement_treatment, :reimbursement_treatment,
            :register_presentation, :effective_from, :source_name, :version,
            presence: true
  validates :component_kind, inclusion: { in: COMPONENT_KINDS }
  validates :fit_treatment, :social_security_treatment, :medicare_treatment,
            :additional_medicare_treatment, inclusion: { in: TAX_TREATMENTS }
  validates :swica_treatment, :retirement_treatment, :reimbursement_treatment,
            inclusion: { in: OTHER_TREATMENTS }
  validates :register_presentation, inclusion: { in: REGISTER_PRESENTATIONS }
  validate :effective_date_range
  validate :company_belongs_to_approver_organization
  validate :effective_range_does_not_overlap

  scope :active, -> { where(active: true) }
  scope :effective_on, ->(date) {
    where("effective_from <= ? AND (effective_to IS NULL OR effective_to >= ?)", date, date)
  }
  scope :for_company_or_global, ->(company_id) { where(company_id: [ nil, company_id ]) }

  def immutable_after_use?
    payroll_liability_entries.exists?
  end

  def readonly?
    persisted? && immutable_after_use?
  end

  def snapshot
    {
      id: id,
      company_id: company_id,
      component_key: component_key,
      display_name: display_name,
      component_kind: component_kind,
      fit_treatment: fit_treatment,
      social_security_treatment: social_security_treatment,
      medicare_treatment: medicare_treatment,
      additional_medicare_treatment: additional_medicare_treatment,
      swica_treatment: swica_treatment,
      retirement_treatment: retirement_treatment,
      reimbursement_treatment: reimbursement_treatment,
      w2_gu_mapping: w2_gu_mapping,
      form_941_mapping: form_941_mapping,
      register_presentation: register_presentation,
      gl_account_code: gl_account_code,
      effective_from: effective_from,
      effective_to: effective_to,
      source_name: source_name,
      source_url: source_url,
      version: version,
      approved_at: approved_at
    }.stringify_keys
  end

  private

  def effective_date_range
    return if effective_from.blank? || effective_to.blank? || effective_to >= effective_from

    errors.add(:effective_to, "must be on or after effective from")
  end

  def company_belongs_to_approver_organization
    return if company.blank? || approved_by.blank?
    return if approved_by.organization_id == company.organization_id

    errors.add(:approved_by, "must belong to the rule company's organization")
  end

  def effective_range_does_not_overlap
    return if component_key.blank? || effective_from.blank?

    relation = self.class.where(company_id: company_id, component_key: component_key, active: true)
    relation = relation.where.not(id: id) if persisted?
    range_end = effective_to || Date.new(9999, 12, 31)
    overlap = relation.where("effective_from <= ? AND COALESCE(effective_to, DATE '9999-12-31') >= ?", range_end, effective_from)
    errors.add(:effective_from, "overlaps another active rule for this component") if overlap.exists?
  end
end
