# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company, optional: true
  belongs_to :organization, optional: true

  validates :action, presence: true
  validates :event_category, presence: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }

  def readonly?
    persisted?
  end

  def self.record!(
    user: Current.user,
    organization_id: nil,
    company_id: Current.company_id,
    action:,
    record_type:,
    record_id: nil,
    subject_name: nil,
    metadata: {},
    ip_address: Current.ip_address,
    user_agent: Current.user_agent,
    request_id: Current.request_id,
    event_category: "activity"
  )
    organization_id ||= Current.organization_id || user&.organization_id || Company.where(id: company_id).pick(:organization_id)

    log = create!(
      user: user,
      organization_id: organization_id,
      company_id: company_id,
      action: action,
      record_type: record_type,
      record_id: record_id,
      subject_name: subject_name,
      metadata: metadata || {},
      ip_address: ip_address,
      user_agent: user_agent,
      request_id: request_id,
      event_category: event_category,
      actor_name: user&.name,
      actor_email: user&.email,
      actor_role: user&.role
    )
    Current.domain_audit_recorded = true unless action == "authentication#signed_in"
    log
  end
end
