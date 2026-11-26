# frozen_string_literal: true

module DemoCompany
  # Track B (Migrate phase): converts named old-shape demo companies
  # (payroll_environment = 'migration_rehearsal', test_workspace_purpose = 'demo',
  # demo = false) to the new shape (payroll_environment = 'live', demo = true,
  # test-workspace columns cleared, employee_account_links.payroll_environment = 'live').
  #
  # Safety guarantees:
  # - Requires an active organization administrator of the target organization.
  # - Refuses to run inside an existing database transaction so SET LOCAL and
  #   post-commit cache invalidation never extend past the intended commit.
  # - Refuses empty company_ids, missing companies, companies outside the actor's
  #   organization, real live clients, practice copies, companies with external
  #   time-tracking/history approval rows, or malformed rows before writing.
  # - Idempotent: already-converted new-shape demo companies succeed as a no-op
  #   with zero writes and zero duplicate audit logs.
  # - Executes the shape transition exclusively through the owner-only
  #   SECURITY DEFINER database function `convert_demo_company_to_flag(...)`
  #   (never granted to `payroll_app`), in one atomic transaction per company
  #   with an AuditLog row in the same transaction.
  # - Dry-run by default: runs inside SET TRANSACTION READ ONLY and reports only
  #   record identifiers and field names without values.
  class ConvertToFlag
    class Refused < StandardError; end

    Change = Data.define(:record_type, :record_id, :company_id, :fields)
    Result = Data.define(:dry_run, :company_ids, :converted_company_ids, :already_converted_company_ids, :changes) do
      def counts
        changes.group_by(&:record_type).transform_values(&:size)
      end
    end

    LOCK_TIMEOUT = "5s"
    AUDIT_ACTION = "demo_company#converted_to_flag"

    # Exact target values for a converted new-shape demo company.
    # test_workspace_manifest is intentionally preserved unchanged so
    # demo_fixture_key remains intact and immutable for seed, rename, and
    # fixture-key uniqueness.
    COMPANY_TARGET_ATTRIBUTES = {
      demo: true,
      payroll_environment: "live",
      test_workspace_purpose: nil,
      migration_rehearsal_status: nil,
      migration_rehearsal_created_by_id: nil,
      migration_rehearsal_created_at: nil,
      migration_rehearsal_completed_at: nil,
      migration_rehearsal_error: nil,
      migration_source_company_id: nil,
      migration_source_batch_id: nil,
      test_workspace_expires_at: nil,
      test_workspace_archived_at: nil,
      test_workspace_sealed_at: nil
    }.freeze

    def initialize(organization:, actor:, company_ids:, dry_run: true)
      @organization = organization
      @actor = actor
      @company_ids = normalize_ids(company_ids)
      @dry_run = dry_run ? true : false
    end

    def call
      ensure_no_open_transaction!
      with_organization_lock do
        system_scope do
          authorize!
          validate_targets_before_write!
          if dry_run
            plan_only
          else
            apply_per_company!
          end
        end
      end
    end

    private

    attr_reader :organization, :actor, :company_ids, :dry_run

    def ensure_no_open_transaction!
      return unless ApplicationRecord.connection.open_transactions.positive?

      raise Refused, "Cannot run demo shape conversion inside an existing database transaction"
    end

    def normalize_ids(raw)
      values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
      raise Refused, "Specify COMPANY_IDS (comma-separated company IDs)" if values.empty?

      values.map { |value| Integer(value, 10) }.uniq
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
      TenantScope.current ? yield : TenantScope.as_system(reason: "Convert legacy demo companies to demo flag", &)
    end

    def validate_targets_before_write!
      found = Company.where(organization_id: organization.id, id: company_ids).order(:id).to_a
      ensure_all_found!(found.map(&:id))

      found.each do |company|
        classify_company!(company)
        ensure_no_time_tracking_history!(company)
      end
    end

    def ensure_all_found!(found_ids)
      missing = company_ids - found_ids
      raise Refused, "Company ID(s) not found in organization: #{missing.join(', ')}" if missing.any?
    end

    def classify_company!(company)
      return :old_shape if old_shape_demo?(company)
      return :already_converted if converted_flag_demo?(company)

      raise Refused, "Refusing to convert company ##{company.id}: it is not an old-shape demo company"
    end

    def ensure_no_time_tracking_history!(company)
      has_history = TimeTrackingSource.where(company_id: company.id).exists? ||
        AireHistoryReview.where(company_id: company.id).exists? ||
        AireVerifiedHistoryRolloutReceipt.where(company_id: company.id).exists?
      return unless has_history

      raise Refused, "Refusing to convert company ##{company.id}: external time-tracking sources or history approvals exist"
    end

    def old_shape_demo?(company)
      company[:demo] == false &&
        company.payroll_environment == "migration_rehearsal" &&
        company.test_workspace_purpose == "demo" &&
        company.migration_source_company_id.nil? &&
        company.migration_source_batch_id.nil? &&
        company.test_workspace_expires_at.nil? &&
        company.test_workspace_archived_at.nil? &&
        company.test_workspace_sealed_at.nil?
    end

    def converted_flag_demo?(company)
      COMPANY_TARGET_ATTRIBUTES.all? { |field, target| company.public_send(field) == target } &&
        EmployeeAccountLink.where(company_id: company.id).where.not(payroll_environment: "live").none?
    end

    def plan_only
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction do
        connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        companies = Company.where(organization_id: organization.id, id: company_ids).order(:id).to_a
        ensure_all_found!(companies.map(&:id))
        changes = []
        to_convert = []
        already_converted = []

        companies.each do |company|
          state = classify_company!(company)
          if state == :already_converted
            already_converted << company.id
            next
          end

          to_convert << company.id
          changes.concat(planned_changes_for(company))
        end

        Result.new(
          dry_run: true,
          company_ids: companies.map(&:id),
          converted_company_ids: to_convert,
          already_converted_company_ids: already_converted,
          changes: changes
        )
      end
    end

    def apply_per_company!
      ordered_ids = Company.where(organization_id: organization.id, id: company_ids).order(:id).pluck(:id)
      ensure_all_found!(ordered_ids)
      changes = []
      converted = []
      already_converted = []

      ordered_ids.each do |company_id|
        outcome, company_changes = convert_single_company!(company_id)
        if outcome == :already_converted
          already_converted << company_id
        else
          converted << company_id
          changes.concat(company_changes)
          TenantSubdomainRegistry.invalidate!
        end
      end

      Result.new(
        dry_run: false,
        company_ids: ordered_ids,
        converted_company_ids: converted,
        already_converted_company_ids: already_converted,
        changes: changes
      )
    end

    def convert_single_company!(company_id)
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction do
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}")

        company = Company.where(organization_id: organization.id).lock.find_by(id: company_id)
        raise Refused, "Company ID(s) not found in organization: #{company_id}" unless company
        state = classify_company!(company)
        ensure_no_time_tracking_history!(company)
        next [ :already_converted, [] ] if state == :already_converted

        links = EmployeeAccountLink.where(company_id: company.id).where.not(payroll_environment: "live").order(:id).lock.to_a
        company_fields = changed_company_fields(company)
        company_changes = build_changes(company, company_fields, links)

        now = Time.current
        links_updated = connection.select_value(
          ApplicationRecord.sanitize_sql_array([
            "SELECT convert_demo_company_to_flag(?, ?)",
            company.id,
            now
          ])
        ).to_i

        company.reload
        unless converted_flag_demo?(company) && links_updated == links.size
          raise Refused, "Post-conversion shape verification failed for company ##{company.id}"
        end

        record_audit!(company, company_fields, links_updated)
        [ :converted, company_changes ]
      end
    end

    def planned_changes_for(company)
      links = EmployeeAccountLink.where(company_id: company.id).where.not(payroll_environment: "live").order(:id).to_a
      build_changes(company, changed_company_fields(company), links)
    end

    def changed_company_fields(company)
      COMPANY_TARGET_ATTRIBUTES.each_with_object([]) do |(field, target), fields|
        fields << field.to_s if company.public_send(field) != target
      end.sort
    end

    def build_changes(company, company_fields, links)
      changes = []
      if company_fields.any?
        changes << Change.new(
          record_type: "company",
          record_id: company.id,
          company_id: company.id,
          fields: company_fields
        )
      end
      links.each do |link|
        changes << Change.new(
          record_type: "employee_account_link",
          record_id: link.id,
          company_id: company.id,
          fields: [ "payroll_environment" ]
        )
      end
      changes
    end

    def record_audit!(company, company_fields, links_updated_count)
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
          company_fields: company_fields,
          employee_account_links_updated: links_updated_count
        }
      )
    end
  end
end
