# frozen_string_literal: true

require "digest"

class User < ApplicationRecord
  INVITATION_STATUSES = %w[pending accepted].freeze
  PRIMARY_PLATFORM_OWNER_EMAIL = "shimizutechnology@gmail.com"

  belongs_to :organization
  belongs_to :company
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :user_sessions, dependent: :destroy
  has_many :audit_logs, dependent: :nullify
  has_many :user_invitations, foreign_key: :invited_by_id, dependent: :nullify
  has_many :company_assignments, dependent: :destroy
  has_many :assigned_companies, through: :company_assignments, source: :company
  has_many :uploaded_client_documents, class_name: "ClientDocument", foreign_key: :uploaded_by_id, dependent: :nullify
  has_many :requested_employee_change_requests, class_name: "EmployeeChangeRequest", foreign_key: :requested_by_id, dependent: :nullify
  has_many :reviewed_employee_change_requests, class_name: "EmployeeChangeRequest", foreign_key: :reviewed_by_id, dependent: :nullify
  has_many :created_general_transmittals, class_name: "GeneralTransmittal", foreign_key: :created_by_id, dependent: :nullify
  has_many :updated_general_transmittals, class_name: "GeneralTransmittal", foreign_key: :updated_by_id, dependent: :nullify
  has_many :created_general_transmittal_artifacts, class_name: "GeneralTransmittalArtifact", foreign_key: :created_by_id, dependent: :nullify
  has_many :created_invoice_chat_sessions, class_name: "InvoiceChatSession", foreign_key: :created_by_id, dependent: :nullify
  has_many :updated_invoice_chat_sessions, class_name: "InvoiceChatSession", foreign_key: :updated_by_id, dependent: :nullify

  enum :role, { admin: 0, manager: 1, employee: 2, accountant: 3, client: 4, super_admin: 5, org_admin: 6 }

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }
  validate :company_must_belong_to_organization
  validate :platform_owner_requirements
  validate :platform_owner_identity_is_immutable, on: :update

  before_validation :default_organization_from_company
  before_destroy :prevent_platform_owner_destroy
  after_update_commit :disconnect_cable_after_deactivation, if: :saved_change_to_active?

  scope :active, -> { where(active: true) }

  ACTIVITY_WRITE_INTERVAL = 5.minutes

  def authenticated_activity_write_due?(session_id: nil, occurred_at: Time.current)
    session_digest = session_id.present? ? Digest::SHA256.hexdigest(session_id.to_s) : nil
    new_session = session_digest.present? && session_digest != last_session_id_digest
    activity_stale = last_active_at.blank? || last_active_at < occurred_at - ACTIVITY_WRITE_INTERVAL

    new_session || activity_stale
  end

  def record_authenticated_activity!(session_id: nil, occurred_at: Time.current)
    session_digest = session_id.present? ? Digest::SHA256.hexdigest(session_id.to_s) : nil
    new_session = session_digest.present? && session_digest != last_session_id_digest

    updates = {}
    if new_session
      updates[:last_session_id_digest] = session_digest
      updates[:last_login_at] = occurred_at
    end
    if last_active_at.blank? || last_active_at < occurred_at - ACTIVITY_WRITE_INTERVAL
      updates[:last_active_at] = occurred_at
    end

    return false if updates.empty?

    update_columns(updates)
    new_session
  end

  def invitation_pending?
    invitation_status == "pending"
  end

  def invitation_accepted?
    invitation_status == "accepted"
  end

  def mark_invitation_accepted!
    update!(invitation_status: "accepted")
  end

  def platform_admin?
    super_admin?
  end

  # A Clerk session proves identity, but the local payroll account remains the
  # authority for access. Platform super admins retain recovery access when a
  # customer organization is inactive; every user must still be active.
  def payroll_access_allowed?
    active? && (super_admin? || organization&.active?)
  end

  def organization_admin?
    super_admin? || admin? || org_admin?
  end

  def staff_member?
    organization_admin? || manager? || accountant?
  end

  # Returns all companies this user can access:
  # - super admins: all companies across all organizations
  # - org admins / legacy admins: every company in their organization
  # - managers/accountants/clients: explicitly assigned companies (or home company)
  # - everyone else: just their home company
  def accessible_company_ids
    @accessible_company_ids ||= begin
      if super_admin?
        Company.ids
      elsif organization_admin?
        organization_company_ids
      else
        assigned_ids = if association(:company_assignments).loaded?
          company_assignments.map(&:company_id)
        else
          company_assignments.pluck(:company_id)
        end
        assigned_ids &= organization_company_ids

        if accountant? || manager? || client?
          # Client-facing users and scoped staff only see explicitly assigned
          # companies (falling back to their home company when none exist yet).
          assigned_ids.presence || Array(company_id)
        else
          ([ company_id ] + assigned_ids).uniq
        end
      end
    end
  end

  def can_access_company?(cid)
    return true if super_admin?

    accessible_company_ids.include?(cid)
  end

  private

  def disconnect_cable_after_deactivation
    PayrollAccess::RevocationDispatcher.call(self) unless active?
  end

  def platform_owner_requirements
    return unless platform_owner?

    errors.add(:email, "must remain #{PRIMARY_PLATFORM_OWNER_EMAIL}") unless email.to_s.casecmp?(PRIMARY_PLATFORM_OWNER_EMAIL)
    errors.add(:role, "must remain Super Admin") unless super_admin?
    errors.add(:active, "must remain active") unless active?
  end

  def platform_owner_identity_is_immutable
    return unless platform_owner_in_database

    errors.add(:email, "cannot be changed for the primary platform owner") if will_save_change_to_email?
    errors.add(:role, "cannot be changed for the primary platform owner") if will_save_change_to_role?
    errors.add(:active, "cannot be changed for the primary platform owner") if will_save_change_to_active?
    errors.add(:platform_owner, "cannot be removed from the primary platform owner") if will_save_change_to_platform_owner?
  end

  def prevent_platform_owner_destroy
    return unless platform_owner?

    errors.add(:base, "The primary platform owner cannot be deleted")
    throw :abort
  end

  def default_organization_from_company
    self.organization ||= company&.organization
  end

  def company_must_belong_to_organization
    return if company.blank? || organization.blank?
    return if company.organization_id == organization_id

    errors.add(:company, "must belong to the user's organization")
  end

  def organization_company_ids
    return [] unless organization

    organization.companies.ids
  end
end
