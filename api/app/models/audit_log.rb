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
    actor = user ? AuditActor.for_user(user) : actor || Current.actor
    current_user = Current.user
    if user.nil? && current_user && actor && %w[staff_user client_user].include?(actor.type)
      user = current_user if actor.id == current_user.id.to_s && actor.type == AuditActor.for_user(current_user).type
    end
    organization_id ||= Current.organization_id || user&.organization_id || Company.where(id: company_id).pick(:organization_id)

    if actor.nil? && Rails.env.production?
      message = "[AuditLog] Missing actor for #{action}"
      Rails.logger.warn(message)
      Rails.error.report(StandardError.new(message), handled: true, severity: :warning, context: { request_id: request_id })
      actor = AuditActor.system_job("Unknown actor")
    end

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
    # Authentication can happen before a separate domain action in the same request.
    Current.domain_audit_recorded = true unless action.start_with?("authentication#")
    log
  end

  private

  def derive_actor
    actor = user ? AuditActor.for_user(user) : Current.actor if actor_type.nil? || user
    return unless actor

    self.actor_type = actor.type
    self.actor_id = actor.id if user || actor_id.nil?
    self.actor_name = actor.name if user || actor_name.nil?
    self.actor_email = actor.email if user || actor_email.nil?
    self.actor_role = actor.role if user || actor_role.nil?
  end
end
