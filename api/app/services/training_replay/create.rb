# frozen_string_literal: true

module TrainingReplay
  class Create
    ACKNOWLEDGEMENT = "CREATE TRAINING REPLAY"
    COMPANY_FIELDS = MigrationRehearsal::Create::COMPANY_FIELDS
    ACCESS_LEVELS = CompanyAssignment::WORKSPACE_ACCESS_LEVELS

    def initialize(source_company:, actor:, acknowledgement:, assignments:, name: nil)
      @source_company = source_company
      @actor = actor
      @name = name.to_s.strip.presence || "#{source_company.name} Training Replay"
      @acknowledgement = acknowledgement
      @assignments = Array(assignments).map(&:to_h)
    end

    def call
      authorize!
      raise ArgumentError, "Confirm that this training workspace contains protected payroll data" unless acknowledgement == ACKNOWLEDGEMENT

      preview = Preview.new(source_company: source_company)
      preview_payload = preview.call
      raise ArgumentError, preview_payload.fetch(:blockers).join("; ") unless preview_payload.fetch(:ready)

      company = build_company(preview_payload, preview.practice_periods)

      Company.transaction do
        source_company.organization.lock!
        if source_company.test_workspaces.active.where(test_workspace_purpose: "training_replay", test_workspace_archived_at: nil).exists?
          raise ArgumentError, "Archive the existing training replay before creating another"
        end

        staff_assignments = validated_assignments!
        company.save!
        staff_assignments.each do |entry|
          CompanyAssignment.create!(
            company: company,
            user: entry.fetch(:user),
            workspace_access_level: entry.fetch(:workspace_access_level),
            expires_at: company.test_workspace_expires_at,
            granted_by: actor
          )
        end
        audit_created!(company, preview_payload, staff_assignments)
      end

      Dispatch.call(company: company, actor: actor)
      company
    rescue ActiveRecord::RecordNotUnique
      raise ArgumentError, "Archive the existing training replay before creating another"
    end

    private

    attr_reader :source_company, :actor, :name, :acknowledgement, :assignments

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(source_company.id) &&
        StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to this client is required" unless allowed
    end

    def validated_assignments!
      raise ArgumentError, "Assign at least one manager or accountant to the training workspace" if assignments.empty?

      raw_ids = assignments.map { |entry| entry[:user_id] || entry["user_id"] }
      raise ArgumentError, "Each assigned staff member requires a user_id" if raw_ids.any?(&:blank?)

      ids = raw_ids.map(&:to_i)
      raise ArgumentError, "Each staff member can be assigned only once" unless ids.uniq.length == ids.length

      users = source_company.organization.users.active.where(id: ids, role: %w[manager accountant]).lock.index_by(&:id)
      raise ArgumentError, "Training access can only be assigned to active managers and accountants in this organization" unless users.length == ids.length

      assignments.map do |entry|
        level = (entry[:workspace_access_level] || entry["workspace_access_level"]).to_s
        raise ArgumentError, "Choose a valid access level for every assigned staff member" unless level.in?(ACCESS_LEVELS)

        { user: users.fetch((entry[:user_id] || entry["user_id"]).to_i), workspace_access_level: level }
      end
    end

    def build_company(preview_payload, practice_periods)
      Company.new(source_company.attributes.slice(*COMPANY_FIELDS).merge(
        name: name,
        organization: source_company.organization,
        active: true,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "training_replay",
        migration_source_company: source_company,
        migration_source_batch: nil,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        migration_rehearsal_error: nil,
        test_workspace_expires_at: 90.days.from_now,
        active_printer_profile: nil,
        test_workspace_manifest: {
          version: 2,
          purpose: "training_replay",
          source_company_id: source_company.id,
          practice_source_pay_period_ids: practice_periods.map(&:id),
          benchmark_mode: "immutable_snapshot",
          copy_summary: preview_payload.fetch(:copy_summary),
          exclusions: preview_payload.fetch(:warnings)
        },
        auto_create_fit_check: false,
        payroll_intake_source_types: []
      ))
    end

    def audit_created!(company, preview_payload, staff_assignments)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "training_replay#create",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: source_company.id,
          copy_summary: preview_payload.fetch(:copy_summary),
          assignments: staff_assignments.map { |entry| { user_id: entry.fetch(:user).id, access: entry.fetch(:workspace_access_level) } }
        }
      )
    end
  end
end
