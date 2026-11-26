# frozen_string_literal: true

require "digest"

class User < ApplicationRecord
  INVITATION_STATUSES = %w[pending accepted].freeze
  PRIMARY_PLATFORM_OWNER_EMAIL = "shimizutechnology@gmail.com"

  belongs_to :organization
  belongs_to :company
  belongs_to :practice_company, class_name: "Company", optional: true
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :portal_document_read_receipts, dependent: :delete_all
  has_many :portal_thread_read_receipts, dependent: :delete_all
  has_many :portal_notification_deliveries, dependent: :delete_all
  has_many :portal_notification_preferences, dependent: :delete_all
  has_many :portal_notification_recipients, dependent: :delete_all
  has_many :user_sessions, dependent: :destroy
  has_many :audit_logs, dependent: :nullify
  has_many :employee_account_links, dependent: :restrict_with_error
  has_many :user_invitations, foreign_key: :invited_by_id, dependent: :nullify
  has_many :company_assignments, dependent: :destroy
  has_many :assigned_companies, through: :company_assignments, source: :company
  has_many :time_tracking_delegations, dependent: :destroy
  has_many :user_printer_profile_selections, dependent: :destroy
  has_many :selected_printer_profiles, through: :user_printer_profile_selections, source: :printer_profile
  has_many :created_printer_profiles, class_name: "PrinterProfile", foreign_key: :created_by_id, dependent: :nullify
  has_many :updated_printer_profiles, class_name: "PrinterProfile", foreign_key: :updated_by_id, dependent: :nullify
  has_many :reviewed_client_documents, class_name: "ClientDocument", foreign_key: :reviewed_by_id, dependent: :restrict_with_error
  has_many :uploaded_client_documents, class_name: "ClientDocument", foreign_key: :uploaded_by_id, dependent: :nullify
  has_many :requested_employee_change_requests, class_name: "EmployeeChangeRequest", foreign_key: :requested_by_id, dependent: :nullify
  has_many :reviewed_employee_change_requests, class_name: "EmployeeChangeRequest", foreign_key: :reviewed_by_id, dependent: :nullify
  has_many :created_general_transmittals, class_name: "GeneralTransmittal", foreign_key: :created_by_id, dependent: :nullify
  has_many :updated_general_transmittals, class_name: "GeneralTransmittal", foreign_key: :updated_by_id, dependent: :nullify
  has_many :created_general_transmittal_artifacts, class_name: "GeneralTransmittalArtifact", foreign_key: :created_by_id, dependent: :nullify
  has_many :created_invoice_chat_sessions, class_name: "InvoiceChatSession", foreign_key: :created_by_id, dependent: :nullify
  has_many :updated_invoice_chat_sessions, class_name: "InvoiceChatSession", foreign_key: :updated_by_id, dependent: :nullify

  enum :role, { admin: 0, manager: 1, employee: 2, accountant: 3, client: 4, super_admin: 5, org_admin: 6, portal_employee: 7 }

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }
  # Why the login was last deactivated (M4-2). Only last_employee_link_closed
  # lets a rehired employee reactivate it themselves; an admin's deactivation
  # (any path that doesn't name a reason) never can.
  DEACTIVATION_REASONS = %w[last_employee_link_closed pending_sign_up_closed deactivated].freeze
  validates :deactivation_reason, inclusion: { in: DEACTIVATION_REASONS }, allow_nil: true
  validate :company_must_belong_to_organization
  validate :migration_rehearsal_company_requires_staff_role
  validate :practice_scope_is_isolated
  validate :platform_owner_requirements
  validate :platform_owner_identity_is_immutable, on: :update
  validate :demo_identity_is_fixed, on: :update

  before_validation :default_organization_from_company
  before_save :record_deactivation, if: :will_save_change_to_active?
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

  def awaiting_clerk_binding?
    invitation_pending? && (clerk_id.blank? || clerk_id.start_with?("pending_"))
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
    if active? && practice_company_id?
      if WriteMaintenance.enabled?
        return false unless practice_portal_open?
      else
        TestWorkspace::PortalAccess.deactivate_if_closed!(self)
      end
    end
    active? && (super_admin? || organization&.active?) && (!demo_client? || demo_client_access_open?) &&
      (!demo_employee? || DemoOutbound.allowed?(email))
  end

  # An employee-app login whose home company is a demo (D6): it works only
  # while its address is on the current allow-list.
  def demo_employee?
    portal_employee? && company&.demo? == true
  end

  # A client login whose home company is a demo (D5).
  def demo_client?
    client? && practice_company_id.nil? && company&.demo? == true
  end

  # A demo client login works only while its address is on the current
  # allow-list and it holds an explicit, unexpired grant to an active, ready
  # demo company. Its home company is never a fallback.
  def demo_client_access_open?
    DemoOutbound.allowed?(email) && demo_client_company_ids.any?
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
  # - managers/accountants: explicitly assigned companies (or home company)
  # - clients: explicitly assigned companies only (never falls back to home company)
  # - employee-only identities: no staff/client company access
  def accessible_company_ids
    @accessible_company_ids ||= begin
      if employee? || portal_employee?
        []
      elsif practice_company_id?
        practice_portal_open? ? [ practice_company_id ] : []
      elsif super_admin?
        Company.ids
      elsif organization_admin?
        organization_company_ids
      elsif demo_client?
        demo_client_access_open? ? effective_client_company_ids : []
      elsif client?
        effective_client_company_ids
      else
        assigned_ids = active_assigned_company_ids
        assigned_ids &= organization_company_ids

        assigned_ids.presence || Array(company_id)
      end
    end
  end

  # Single source of truth for effective client company grants (enforcing
  # expiry, archive timestamps, organization boundary, practice-copy readiness,
  # and demo-company readiness). Used by authorization and by activation and
  # assignment mutation guards under the user lock.
  def effective_client_company_ids(fresh: false)
    return [] unless client?
    return practice_portal_open? ? [ practice_company_id ] : [] if practice_company_id?
    return fresh ? query_demo_client_company_ids : demo_client_company_ids if demo_client?

    assigned_ids = active_assigned_company_ids(fresh: fresh) & organization_company_ids
    client_company_boundary(assigned_ids)
  end

  def has_effective_client_grant?
    effective_client_company_ids(fresh: true).any?
  end

  def reload(...)
    @accessible_company_ids = nil
    @demo_client_company_ids = nil
    super
  end

  def can_access_company?(cid)
    return true if super_admin?

    accessible_company_ids.include?(cid)
  end

  def practice_portal_open?
    workspace = Company.find_by(id: practice_company_id)
    client? && company_id == practice_company_id && workspace&.sandbox? && workspace.active? &&
      workspace.test_workspace_ready? && !workspace.test_workspace_read_only? &&
      (new_record? || company_assignments.active_access.exists?(company_id: practice_company_id))
  end

  # TestWorkspace::MovePracticeLogin is the only path that may re-point a
  # practice-only login, and only after it has checked both copies.
  def allow_practice_company_move!
    @practice_company_move_allowed = true
  end

  def reset_practice_company_move!
    @practice_company_move_allowed = false
  end

  private

  # deactivated_at stays after reactivation: sessions from before it remain
  # refused (EmployeeLinks::SessionFence).
  def record_deactivation
    if active?
      self.deactivation_reason = nil
    elsif persisted?
      self.deactivated_at = ApplicationRecord.database_now unless will_save_change_to_deactivated_at?
      self.deactivation_reason = "deactivated" unless will_save_change_to_deactivation_reason?
    end
  end

  def practice_scope_is_isolated
    if practice_company_id_in_database.present? && will_save_change_to_practice_company_id?
      if !@practice_company_move_allowed
        errors.add(:practice_company, "cannot be changed for a practice-only login")
      elsif practice_company_id.blank?
        errors.add(:practice_company, "must remain a practice copy")
      end
    end
    return unless practice_company_id?

    errors.add(:base, "A practice-only login must remain a client of its practice copy") unless client? && company_id == practice_company_id
    errors.add(:base, "This practice login can't be active while its practice copy is archived, expired or not ready") if active? && !practice_portal_open?
    if company_assignments.where.not(company_id: practice_company_id).exists?
      errors.add(:base, "A practice-only login cannot be assigned to another client")
    end
  end

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

  # A live client login never sees a demo company, whatever its assignments
  # or home company say (demo client logins: demo_client_company_ids).
  def client_company_boundary(ids)
    return ids unless client? && ids.any?

    ids - Company.demo.where(id: ids).ids
  end

  def demo_client_company_ids
    @demo_client_company_ids ||= query_demo_client_company_ids
  end

  def query_demo_client_company_ids
    company_assignments.active_access.joins(:company)
      .merge(Company.demo.active)
      .where(companies: { organization_id: organization_id, migration_rehearsal_status: "ready", test_workspace_archived_at: nil })
      .order(:company_id).pluck(:company_id)
  end

  def active_assigned_company_ids(fresh: false)
    if !fresh && association(:company_assignments).loaded?
      active_assignments = company_assignments.reject(&:expired?)
      active_assignment_company_ids = active_assignments.map(&:company_id)

      if active_assignments.all? { |assignment| assignment.association(:company).loaded? }
        active_assignments.filter_map do |assignment|
          assignment.company_id unless assignment.company&.test_workspace_archived_at?
        end
      else
        archived_company_ids = Company.where(id: active_assignment_company_ids)
          .where.not(test_workspace_archived_at: nil)
          .pluck(:id)
        active_assignment_company_ids - archived_company_ids
      end
    else
      company_assignments.active_access
        .joins(:company)
        .where(companies: { test_workspace_archived_at: nil })
        .pluck(:company_id)
    end
  end

  def migration_rehearsal_company_requires_staff_role
    return if company.blank? || !company.test_workspace? || staff_member? || (client? && practice_company_id == company_id)
    # A demo company's client and employee-app logins are its own: only
    # allow-listed addresses (private configuration), never a practice login.
    return if (client? || portal_employee?) && company.demo? && practice_company_id.nil? &&
      (closing_demo_login? || DemoOutbound.allowed?(email))

    errors.add(:company, "requires a practice-only client login or payroll staff")
  end

  # Saving an existing demo login without changing who it is or turning it
  # on works even after its address left the allow-list: deactivating it, or
  # clearing a pending sign-up's invitation and nonce.
  def closing_demo_login?
    persisted? && !will_save_change_to_email? && !will_save_change_to_role? && !will_save_change_to_company_id? &&
      !will_save_change_to_clerk_id? && !(will_save_change_to_active? && active?)
  end

  # A demo client or employee-app identity stays what it is, on a demo: a
  # role edit can't turn its Clerk identity into firm staff (or a client into
  # an employee login), and its home can't move to a live client.
  def demo_identity_is_fixed
    return unless %w[client portal_employee].include?(role_in_database) && practice_company_id_in_database.nil? &&
      Company.find_by(id: company_id_in_database)&.demo?

    errors.add(:role, "can't be changed for this login. Create a separate login for staff access.") if will_save_change_to_role?
    errors.add(:company, "can't be changed for this login") unless company&.demo?
  end

  def organization_company_ids
    return [] unless organization

    organization.companies.ids
  end
end
