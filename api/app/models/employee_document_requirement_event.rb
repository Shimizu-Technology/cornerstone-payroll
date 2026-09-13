# frozen_string_literal: true

class EmployeeDocumentRequirementEvent < ApplicationRecord
  EVENT_TYPES = %w[document_received status_changed].freeze

  belongs_to :employee_document_requirement
  belongs_to :company
  belongs_to :employee
  belongs_to :client_document, optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :to_status, inclusion: { in: EmployeeDocumentRequirement::STATUSES }
  validates :from_status, inclusion: { in: EmployeeDocumentRequirement::STATUSES }, allow_nil: true
  validate :scope_matches_requirement
  validate :document_matches_scope
  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def scope_matches_requirement
    return if employee_document_requirement.blank?
    return if company_id == employee_document_requirement.company_id && employee_id == employee_document_requirement.employee_id

    errors.add(:base, "Event scope must match the document requirement")
  end

  def document_matches_scope
    return if client_document.blank?
    return if client_document.company_id == company_id && client_document.employee_id == employee_id

    errors.add(:client_document, "must belong to this employee and company")
  end

  def prevent_mutation
    errors.add(:base, "Employee document readiness history is append-only")
    throw :abort
  end
end
