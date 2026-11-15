# frozen_string_literal: true

module TestWorkspace
  # Moves a practice-only client login from a closed practice copy to another
  # open practice copy in the same organization. Only access moves: payroll
  # submissions, documents and audit rows the login wrote in the old copy keep
  # it as their author, and the login can never reach a real client.
  class MovePracticeLogin
    class Refused < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    # The copy-level half of User#practice_portal_open?. A login whose copy is
    # open keeps that copy; it is moved only once the copy has closed.
    def self.open_copy?(company)
      closed_reason(company).nil?
    end

    def self.closed_reason(company)
      return "no longer available" if company.blank? || !company.sandbox?
      return "archived" if company.test_workspace_archived_at.present?
      return "expired" if company.test_workspace_expired?
      return "a read-only snapshot" if company.test_workspace_read_only?
      return "still being prepared" if company.migration_rehearsal_status == "pending"
      return "not ready" unless company.test_workspace_ready?
      return "inactive" unless company.active? && company.organization&.active?

      nil
    end

    attr_reader :source_company

    def initialize(user:, target_company:, actor:, activate:)
      @user = user
      @target_company = target_company
      @actor = actor
      @activate = ActiveModel::Type::Boolean.new.cast(activate) == true
    end

    def call
      authorize!

      User.transaction do
        user.lock!
        @source_company = user.practice_company
        validate_source!
        validate_target!

        user.company_assignments.destroy_all
        user.allow_practice_company_move!
        # Access is closed during the move; it reopens only after the new
        # assignment exists, so practice_portal_open? holds whenever active.
        user.update!(company: target_company, practice_company: target_company, active: false)
        CompanyAssignment.create!(user: user, company: target_company, granted_by: actor)
        user.association(:company_assignments).reset
        user.update!(active: true) if activate
        audit!
      end

      user
    ensure
      user.reset_practice_company_move!
    end

    private

    attr_reader :user, :target_company, :actor, :activate

    def authorize!
      allowed = actor&.organization_admin? && actor.payroll_access_allowed? &&
        (actor.super_admin? || actor.organization_id == user.organization_id)
      refuse!("Only an organization administrator can move a practice login", :forbidden) unless allowed
    end

    def validate_source!
      unless user.client? && user.practice_company_id? && source_company.present?
        refuse!("Only a practice-only client login can be moved between practice copies", :not_practice_login)
      end
      return unless self.class.open_copy?(source_company)

      refuse!(
        "#{display_name} still has an open practice copy (#{source_company.name}). " \
        "Keep using it, or archive that copy before moving the login.",
        :source_copy_open
      )
    end

    def validate_target!
      if target_company.blank? || target_company.organization_id != user.organization_id ||
         !actor.can_access_company?(target_company.id)
        refuse!("Choose a practice copy in this organization", :target_unavailable)
      end
      unless target_company.test_workspace?
        refuse!("A practice login can use a practice copy only, never a real client", :target_not_practice_copy)
      end
      unless target_company.sandbox?
        refuse!(
          "#{target_company.name} is a #{target_company.test_workspace_purpose_label.to_s.downcase}, not a practice copy. Choose a general test workspace.",
          :target_not_practice_copy
        )
      end
      reason = self.class.closed_reason(target_company)
      refuse!("#{target_company.name} is #{reason}. Choose a ready practice copy.", :target_unavailable) if reason
    end

    def audit!
      AuditLog.record!(
        user: actor,
        organization_id: user.organization_id,
        company_id: target_company.id,
        action: "users#practice_copy_moved",
        record_type: "users",
        record_id: user.id,
        subject_name: display_name,
        metadata: {
          from_company_id: source_company.id,
          from_company_name: source_company.name,
          to_company_id: target_company.id,
          to_company_name: target_company.name,
          activated: activate,
          changed_fields: %w[practice_company_id assigned_company_ids] + (activate ? %w[active] : [])
        },
        event_category: "security"
      )
    end

    def display_name
      user.name.presence || user.email
    end

    def refuse!(message, code)
      raise Refused.new(message, code: code)
    end
  end
end
