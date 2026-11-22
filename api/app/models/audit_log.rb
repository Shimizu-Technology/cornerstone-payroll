# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company, optional: true
  belongs_to :organization, optional: true

  before_validation :derive_actor, on: :create

  validates :actor_type, inclusion: { in: AuditActor::TYPES }
  validates :actor_name, presence: true, unless: :user

  validates :action, presence: true
  validates :event_category, presence: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }

  def readonly?
    persisted?
  end

  def self.record!(
    actor: nil,
    user: (Current.user unless actor),
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

    actor = user ? AuditActor.for_user(user) : actor || Current.actor

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
      actor_type: actor&.type,
      actor_id: actor&.id,
      actor_name: actor&.name,
      actor_email: actor&.email,
      actor_role: actor&.role
    )
    Current.domain_audit_recorded = true unless action == "authentication#signed_in"
    log
  end

  private

  def derive_actor
    actor = user ? AuditActor.for_user(user) : Current.actor if actor_type.nil? || user
    return unless actor

    self.actor_type = actor.type
    self.actor_id ||= actor.id
    self.actor_name ||= actor.name
    self.actor_email ||= actor.email
    self.actor_role ||= actor.role
  end
end
