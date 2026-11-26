# frozen_string_literal: true

module DemoCompany
  # Targeted per-company rollback for the Track B demo-shape migration.
  #
  # Restores a converted flag-shape demo company back to its exact captured
  # pre-conversion legacy shape (from the `before` snapshot produced by
  # DemoCompany::VerifyShapeMigration) without touching unrelated production
  # writes or requiring a whole-database restore.
  #
  # Executes through the owner-only SECURITY DEFINER database function
  # `revert_demo_company_to_legacy_shape(...)` (never granted to `payroll_app`).
  # Refuses if the company is not a converted flag-shape demo, if the before
  # snapshot is missing or invalid, or if any post-conversion filing/liability/
  # non-employee-check rows were created.
  class RevertToLegacyShape
    class Refused < StandardError; end

    Result = Data.define(:dry_run, :reverted_company_ids, :already_legacy_company_ids, :links_reverted)

    LOCK_TIMEOUT = "5s"
    AUDIT_ACTION = "demo_company#reverted_to_legacy_shape"

    def initialize(organization:, actor:, company_ids:, before_snapshot:, dry_run: true)
      @organization = organization
      @actor = actor
      @company_ids = normalize_ids(company_ids)
      @before_snapshot = VerifyShapeMigration.stringify_deep(before_snapshot)
      @dry_run = dry_run ? true : false
    end

    def call
      ensure_no_open_transaction!
      with_organization_lock do
        system_scope do
          authorize!
          plans = build_and_validate_plans!
          if dry_run
            Result.new(
              dry_run: true,
              reverted_company_ids: plans.select { |p| p[:state] == :converted }.map { |p| p[:company_id] },
              already_legacy_company_ids: plans.select { |p| p[:state] == :already_legacy }.map { |p| p[:company_id] },
              links_reverted: plans.sum { |p| p[:links_to_revert] }
            )
          else
            apply_plans!(plans)
          end
        end
      end
    end

    private

    attr_reader :organization, :actor, :company_ids, :before_snapshot, :dry_run

    def ensure_no_open_transaction!
      return unless ApplicationRecord.connection.open_transactions.positive?

      raise Refused, "Cannot run demo shape revert inside an existing database transaction"
    end

    def normalize_ids(raw)
      values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
      raise Refused, "Specify COMPANY_IDS (comma-separated company IDs)" if values.empty?

      values.map { |value| Integer(value, 10) }.uniq.sort
    rescue ArgumentError
      raise Refused, "Company IDs must be integers"
    end

    def authorize!
      allowed = organization.present? && actor&.organization_admin? &&
        actor.payroll_access_allowed?(deactivate_closed_practice: false) &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    def with_organization_lock(&)
      DedicatedAdvisoryLock.with_lock(Seed::LOCK_KEY_BASE + Integer(organization.id), wait_seconds: 0, &)
    rescue DedicatedAdvisoryLock::Unavailable
      raise Refused, "Another demo operation is in progress for this organization"
    end

    def system_scope(&)
      TenantScope.current ? yield : TenantScope.as_system(reason: "Revert converted demo company to legacy shape", &)
    end

    def build_and_validate_plans!
      unless before_snapshot.is_a?(Hash) &&
        before_snapshot["schema_version"] == VerifyShapeMigration::SCHEMA_VERSION &&
        before_snapshot["organization_id"] == organization.id &&
        before_snapshot["companies"].is_a?(Hash)
        raise Refused, "Before snapshot is invalid or belongs to a different organization"
      end

      found = Company.where(organization_id: organization.id, id: company_ids).order(:id).index_by(&:id)
      missing = company_ids - found.keys
      raise Refused, "Company ID(s) not found in organization: #{missing.join(', ')}" if missing.any?

      company_ids.map do |cid|
        company = found.fetch(cid)
        entry = before_snapshot.dig("companies", cid.to_s)
        shape = entry.is_a?(Hash) ? entry["shape"] : nil
        before_company = shape.is_a?(Hash) ? shape["company"] : nil
        unless before_company.is_a?(Hash) &&
          before_company["demo"] == false &&
          before_company["payroll_environment"] == "migration_rehearsal" &&
          before_company["test_workspace_purpose"] == "demo" &&
          before_company["migration_rehearsal_status"] == "ready"
          raise Refused, "Before snapshot does not contain a valid legacy demo shape for company ##{cid}"
        end

        state = if company[:demo] == true && company.payroll_environment == "live" && company.test_workspace_purpose.nil?
          :converted
        elsif company[:demo] == false && company.payroll_environment == "migration_rehearsal" && company.test_workspace_purpose == "demo"
          :already_legacy
        else
          raise Refused, "Refusing to revert company ##{cid}: unexpected current shape"
        end

        ensure_no_lifted_records!(company) if state == :converted

        links_to_revert = state == :converted ? EmployeeAccountLink.where(company_id: cid).where.not(payroll_environment: "migration_rehearsal").count : 0
        {
          company_id: cid,
          state: state,
          migration_rehearsal_status: before_company["migration_rehearsal_status"],
          migration_rehearsal_created_by_id: before_company["migration_rehearsal_created_by_id"],
          migration_rehearsal_created_at: parse_time(before_company["migration_rehearsal_created_at"]),
          migration_rehearsal_completed_at: parse_time(before_company["migration_rehearsal_completed_at"]),
          links_to_revert: links_to_revert
        }
      end
    end

    def ensure_no_lifted_records!(company)
      blocking = [
        PayrollFilingRecord.where(company_id: company.id).exists?,
        PayrollFilingEvent.where(company_id: company.id).exists?,
        PayrollLiabilityPosting.where(company_id: company.id).exists?,
        PayrollLiabilityEntry.where(company_id: company.id).exists?,
        NonEmployeeCheck.where(company_id: company.id).exists?
      ].any?
      return unless blocking

      raise Refused, "Refusing to revert company ##{company.id}: post-conversion filing, liability, or non-employee check rows exist"
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Refused, "Before snapshot contains an invalid timestamp: #{value.inspect}"
    end

    def apply_plans!(plans)
      reverted = []
      already_legacy = []
      total_links = 0

      plans.each do |plan|
        if plan[:state] == :already_legacy
          already_legacy << plan[:company_id]
          next
        end

        links_updated = revert_single_company!(plan)
        reverted << plan[:company_id]
        total_links += links_updated
        TenantSubdomainRegistry.invalidate!
      end

      Result.new(
        dry_run: false,
        reverted_company_ids: reverted,
        already_legacy_company_ids: already_legacy,
        links_reverted: total_links
      )
    end

    def revert_single_company!(plan)
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction do
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}")
        company = Company.where(organization_id: organization.id).lock.find(plan[:company_id])
        ensure_no_lifted_records!(company)

        EmployeeAccountLink.where(company_id: company.id).order(:id).lock.load
        now = Time.current
        links_updated = connection.select_value(
          ApplicationRecord.sanitize_sql_array([
            "SELECT revert_demo_company_to_legacy_shape(?, ?, ?, ?, ?, ?)",
            company.id,
            plan[:migration_rehearsal_status],
            plan[:migration_rehearsal_created_by_id],
            plan[:migration_rehearsal_created_at],
            plan[:migration_rehearsal_completed_at],
            now
          ])
        ).to_i

        company.reload
        unless company[:demo] == false && company.payroll_environment == "migration_rehearsal" && company.test_workspace_purpose == "demo"
          raise Refused, "Post-revert shape verification failed for company ##{company.id}"
        end

        AuditLog.record!(
          user: actor,
          organization_id: organization.id,
          company_id: company.id,
          action: AUDIT_ACTION,
          record_type: "Company",
          record_id: company.id,
          subject_name: company.name,
          metadata: {
            fixture_key: company.test_workspace_manifest["demo_fixture_key"],
            employee_account_links_reverted: links_updated
          }
        )
        links_updated
      end
    end
  end
end
