# frozen_string_literal: true

module TestWorkspace
  class Create
    ACKNOWLEDGEMENT = "CREATE TEST WORKSPACE"
    EXPIRATION_DAYS = [ 30, 60, 90, 180 ].freeze
    COMPANY_FIELDS = MigrationRehearsal::Create::COMPANY_FIELDS
    ACCESS_LEVELS = CompanyAssignment::WORKSPACE_ACCESS_LEVELS

    def initialize(source_company:, actor:, acknowledgement:, assignments:, name: nil, copy_mode: "all_committed",
                   excluded_payrolls: 2, cutoff_pay_period_id: nil, expiration_days: 90)
      @source_company = source_company
      @actor = actor
      @acknowledgement = acknowledgement
      @assignments = Array(assignments).map(&:to_h)
      @name = name.to_s.strip.presence || "#{source_company.name} Test Workspace"
      @copy_mode = copy_mode.to_s
      @excluded_payrolls = excluded_payrolls.to_i
      @cutoff_pay_period_id = cutoff_pay_period_id
      @expiration_days = expiration_days.to_i
    end

    def call
      authorize!
      raise ArgumentError, "Confirm that this workspace contains protected payroll data" unless acknowledgement == ACKNOWLEDGEMENT
      raise ArgumentError, "Choose a supported expiration" unless expiration_days.in?(EXPIRATION_DAYS)

      preview = Preview.new(
        source_company: source_company,
        copy_mode: copy_mode,
        excluded_payrolls: excluded_payrolls,
        cutoff_pay_period_id: cutoff_pay_period_id
      )
      payload = preview.call
      raise ArgumentError, payload.fetch(:blockers).join("; ") unless payload.fetch(:ready)

      periods = preview.selected_periods
      company = build_company(payload, periods)

      Company.transaction do
        source_company.lock!
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
        audit_created!(company, payload, staff_assignments)
      end

      Dispatch.call(company: company, actor: actor)
      company
    end

    private

    attr_reader :source_company, :actor, :acknowledgement, :assignments, :name, :copy_mode,
                :excluded_payrolls, :cutoff_pay_period_id, :expiration_days

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(source_company.id) &&
        StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to this client is required" unless allowed
    end

    def validated_assignments!
      return [] if assignments.empty?

      raw_ids = assignments.map { |entry| entry[:user_id] || entry["user_id"] }
      raise ArgumentError, "Each assigned staff member requires a user_id" if raw_ids.any?(&:blank?)

      ids = raw_ids.map(&:to_i)
      raise ArgumentError, "Each staff member can be assigned only once" unless ids.uniq.length == ids.length

      users = source_company.organization.users.active.where(id: ids, role: %w[manager accountant]).lock.index_by(&:id)
      unless users.length == ids.length
        raise ArgumentError, "Test workspace access can only be assigned to active managers and accountants in this organization"
      end

      assignments.map do |entry|
        level = (entry[:workspace_access_level] || entry["workspace_access_level"]).to_s
        raise ArgumentError, "Choose a valid access level for every assigned staff member" unless level.in?(ACCESS_LEVELS)

        { user: users.fetch((entry[:user_id] || entry["user_id"]).to_i), workspace_access_level: level }
      end
    end

    def build_company(payload, periods)
      last_pay_date = periods.filter_map(&:pay_date).max
      Company.new(source_company.attributes.slice(*COMPANY_FIELDS).merge(
        name: name,
        organization: source_company.organization,
        active: true,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: source_company,
        migration_source_batch: nil,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        migration_rehearsal_error: nil,
        test_workspace_expires_at: expiration_days.days.from_now,
        active_printer_profile: nil,
        test_workspace_manifest: {
          version: 1,
          purpose: "sandbox",
          source_company_id: source_company.id,
          copy_mode: copy_mode,
          excluded_payrolls: copy_mode == "exclude_recent" ? excluded_payrolls : 0,
          cutoff_pay_period_id: copy_mode == "through_pay_period" ? cutoff_pay_period_id.to_i : nil,
          copied_source_pay_period_ids: periods.map(&:id),
          copied_through_pay_date: last_pay_date&.iso8601,
          copy_summary: payload.fetch(:copy_summary),
          exclusions: payload.fetch(:warnings)
        },
        auto_create_fit_check: false,
        payroll_intake_source_types: []
      ))
    end

    def audit_created!(company, payload, staff_assignments)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "test_workspace#create",
        record_type: "companies",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          source_company_id: source_company.id,
          copy_mode: copy_mode,
          copy_summary: payload.fetch(:copy_summary),
          expires_at: company.test_workspace_expires_at,
          assignments: staff_assignments.map { |entry| { user_id: entry.fetch(:user).id, access: entry.fetch(:workspace_access_level) } }
        }
      )
    end
  end
end
