# frozen_string_literal: true

class EmployeeDocumentRequirement < ApplicationRecord
  REQUIREMENT_TYPES = {
    "identity_and_work_authorization" => "Identity and work authorization",
    "withholding_election" => "Signed withholding election",
    "contractor_tax_form" => "Signed contractor tax form"
  }.freeze
  STATUSES = %w[missing received verified rejected waived].freeze
  SATISFIED_STATUSES = %w[verified waived].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :client_document, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :events, class_name: "EmployeeDocumentRequirementEvent", dependent: :restrict_with_error

  validates :requirement_type, inclusion: { in: REQUIREMENT_TYPES.keys }
  validates :label, presence: true, length: { maximum: 120 }
  validates :status, inclusion: { in: STATUSES }
  validate :company_matches_employee
  validate :document_matches_employee
  validate :review_evidence_is_complete

  scope :required_for_payroll, -> { where(required_for_payroll: true) }
  scope :unresolved, -> { where.not(status: SATISFIED_STATUSES) }

  def satisfied?
    status.in?(SATISFIED_STATUSES)
  end

  private

  def company_matches_employee
    return if employee.blank? || company_id == employee.company_id

    errors.add(:company_id, "must match the employee company")
  end

  def document_matches_employee
    return if client_document.blank?
    return if client_document.company_id == company_id && client_document.employee_id == employee_id

    errors.add(:client_document, "must belong to this employee and company")
  end

  def review_evidence_is_complete
    if status.in?(%w[received verified rejected]) && client_document.blank?
      errors.add(:client_document, "is required when a document has been received")
    end
    return unless status.in?(%w[verified rejected waived])

    errors.add(:reviewed_by, "is required for a reviewed outcome") if reviewed_by.blank?
    errors.add(:reviewed_at, "is required for a reviewed outcome") if reviewed_at.blank?
    errors.add(:review_note, "must explain the reviewed outcome") if review_note.to_s.strip.blank?
  end
end
