# frozen_string_literal: true

class TimeTrackingEmployeeMapping < ApplicationRecord
  class IdentityConflict < StandardError; end

  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :employee

  validates :source_user_id, presence: true
  validates :source_user_id, uniqueness: { scope: [ :company_id, :time_tracking_source_id ] }
  validates :source_user_uuid, uniqueness: { scope: [ :company_id, :time_tracking_source_id ] }, allow_nil: true
  validates :source_user_uuid, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }, allow_nil: true
  validates :employee_id,
            uniqueness: {
              scope: [ :company_id, :time_tracking_source_id ],
              conditions: -> { where.not(source_user_uuid: nil) }
            },
            if: -> { source_user_uuid.present? }
  validate :employee_belongs_to_company

  def self.resolve_source_identity!(company:, source:, source_user_id:, source_user_uuid:)
    source_id = source_user_id.to_s
    source_uuid = source_user_uuid.to_s.presence
    by_id = find_by(company: company, time_tracking_source: source, source_user_id: source_id)
    return by_id unless source_uuid

    by_uuid = find_by(company: company, time_tracking_source: source, source_user_uuid: source_uuid)
    if by_uuid && by_id && by_uuid.id != by_id.id
      raise IdentityConflict, "AIRE staff identity conflicts with two saved payroll mappings"
    end
    if by_id&.source_user_uuid.present? && by_id.source_user_uuid != source_uuid
      raise IdentityConflict, "AIRE staff ID is already linked to a different permanent identity"
    end

    by_uuid || by_id
  end

  private

  def employee_belongs_to_company
    return if employee.nil? || employee.company_id == company_id

    errors.add(:employee, "must belong to the same company")
  end
end
