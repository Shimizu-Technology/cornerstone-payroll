# frozen_string_literal: true

class EmployeeDocumentRequirementReviewService
  class Error < StandardError; end
  REVIEWED_STATUSES = %w[verified rejected waived].freeze
  UPDATABLE_STATUSES = %w[received verified rejected waived].freeze

  def initialize(requirement:, actor:, attributes:)
    @requirement = requirement
    @actor = actor
    @attributes = attributes.to_h.symbolize_keys
  end

  def call!
    status = attributes[:status].to_s
    raise Error, "Choose a supported readiness status" unless status.in?(UPDATABLE_STATUSES)
    raise Error, "Include the current checklist version" if attributes[:lock_version].blank?

    ApplicationRecord.transaction do
      Company.lock.find(requirement.company_id)
      requirement.lock!
      unless requirement.lock_version == Integer(attributes[:lock_version], exception: false)
        raise ActiveRecord::StaleObjectError.new(requirement, "update")
      end

      document = selected_document
      review_note = attributes[:review_note].to_s.strip.presence
      if REVIEWED_STATUSES.include?(status) && review_note.blank?
        raise Error, "Explain the reviewed outcome"
      end

      prior_status = requirement.status
      requirement.update!(
        status: status,
        client_document: document,
        received_at: received_at_for(document),
        reviewed_by: REVIEWED_STATUSES.include?(status) ? actor : nil,
        reviewed_at: REVIEWED_STATUSES.include?(status) ? Time.current : nil,
        review_note: REVIEWED_STATUSES.include?(status) ? review_note : nil
      )
      requirement.events.create!(
        company: requirement.company,
        employee: requirement.employee,
        client_document: document,
        document_title: document&.title,
        actor: actor,
        event_type: "status_changed",
        from_status: prior_status,
        to_status: status,
        note: REVIEWED_STATUSES.include?(status) ? review_note : nil
      )
    end

    requirement
  end

  private

  attr_reader :requirement, :actor, :attributes

  def selected_document
    return nil if attributes[:status].to_s == "waived"

    document_id = attributes[:client_document_id].presence || requirement.client_document_id
    raise Error, "Attach the employee document before recording this status" if document_id.blank?

    ClientDocument.find_by(
      id: document_id,
      company_id: requirement.company_id,
      employee_id: requirement.employee_id
    ) || raise(Error, "The selected document does not belong to this employee")
  end

  def received_at_for(document)
    return nil if document.blank?
    return Time.current if document.id != requirement.client_document_id

    requirement.received_at || Time.current
  end
end
