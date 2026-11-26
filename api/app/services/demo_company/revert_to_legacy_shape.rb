# frozen_string_literal: true

module DemoCompany
  # Targeted per-company rollback for the Track B demo-shape migration.
  #
  # Bound strictly to a recorded `DemoShapeConversion` ID written by
  # `convert_demo_company_to_flag(...)`. Never accepts external snapshots or
  # free-form metadata, so a never-converted flag demo cannot be reverted with
  # invented legacy metadata.
  #
  # Requires `WriteMaintenance.enabled?` (WRITE_MAINTENANCE=true) to fence
  # concurrent inserts while reverting, and executes through the owner-only
  # SECURITY DEFINER function `revert_demo_company_to_legacy_shape(...)`
  # (never granted to `payroll_app`), which takes `FOR UPDATE` on the company
  # row before checking post-conversion filing/liability/non-employee-check rows.
  class RevertToLegacyShape
    class Refused < StandardError; end

    Result = Data.define(:dry_run, :conversion_id, :company_id, :links_reverted)

    LOCK_TIMEOUT = "5s"
    AUDIT_ACTION = "demo_company#reverted_to_legacy_shape"

    def initialize(organization:, actor:, conversion_id:, dry_run: true)
      @organization = organization
      @actor = actor
      @conversion_id = normalize_conversion_id(conversion_id)
      @dry_run = dry_run ? true : false
    end

    def call
      ensure_no_open_transaction!
      ensure_write_maintenance_enabled!
      with_organization_lock do
        system_scope do
          authorize!
          if dry_run
            plan_only
          else
            apply_revert!
          end
        end
      end
    end

    private

    attr_reader :organization, :actor, :conversion_id, :dry_run

    def ensure_no_open_transaction!
      return unless ApplicationRecord.connection.open_transactions.positive?

      raise Refused, "Cannot run demo shape revert inside an existing database transaction"
    end

    def ensure_write_maintenance_enabled!
      return if WriteMaintenance.enabled?

      raise Refused, "WriteMaintenance must be enabled (WRITE_MAINTENANCE=true) before reverting a demo shape conversion"
    end

    def normalize_conversion_id(raw)
      text = raw.to_s.strip
      raise Refused, "Specify CONVERSION_ID (integer ID from demo_shape_conversions)" if text.empty?

      value = Integer(text, 10)
      raise Refused, "CONVERSION_ID must be a positive integer" unless value.positive?

      value
    rescue ArgumentError
      raise Refused, "CONVERSION_ID must be a positive integer"
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

    def load_and_validate_conversion!(lock: false)
      scope = DemoShapeConversion.where(organization_id: organization.id)
      scope = scope.lock if lock
      conversion = scope.find_by(id: conversion_id)
      raise Refused, "Demo shape conversion ##{conversion_id} not found in organization" unless conversion
      raise Refused, "Demo shape conversion ##{conversion_id} has already been reverted" if conversion.reverted?

      company_scope = Company.where(organization_id: organization.id)
      company_scope = company_scope.lock if lock
      company = company_scope.find_by(id: conversion.company_id)
      raise Refused, "Company ##{conversion.company_id} not found in organization" unless company

      ensure_current_shape_matches_conversion!(company, conversion)
      ensure_no_lifted_records!(company)
      [ conversion, company ]
    end

    def ensure_current_shape_matches_conversion!(company, conversion)
      expected_manifest = conversion.after_company_shape["test_workspace_manifest"]
      matches_company = ConvertToFlag::COMPANY_TARGET_ATTRIBUTES.all? { |field, target| company.public_send(field) == target } &&
        company.test_workspace_manifest == expected_manifest
      matches_links = EmployeeAccountLink.where(company_id: company.id).where.not(payroll_environment: "live").none?

      return if matches_company && matches_links

      raise Refused, "Refusing to revert conversion ##{conversion.id}: company ##{company.id} current shape differs from what the conversion wrote"
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

    def plan_only
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction do
        connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        conversion, company = load_and_validate_conversion!(lock: false)
        before_links = conversion.before_link_environments.to_h
        links_to_revert = EmployeeAccountLink.where(company_id: company.id).pluck(:id, :payroll_environment).count do |id, env|
          target_env = before_links.fetch(id.to_s, "migration_rehearsal")
          env != target_env
        end

        Result.new(
          dry_run: true,
          conversion_id: conversion.id,
          company_id: company.id,
          links_reverted: links_to_revert
        )
      end
    end

    def apply_revert!
      connection = ApplicationRecord.connection
      result = ApplicationRecord.transaction do
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}")
        conversion, company = load_and_validate_conversion!(lock: true)
        EmployeeAccountLink.where(company_id: company.id).order(:id).lock.load

        now = Time.current
        links_updated = connection.select_value(
          ApplicationRecord.sanitize_sql_array([
            "SELECT revert_demo_company_to_legacy_shape(?, ?, ?, ?)",
            conversion.id,
            actor.id,
            WriteMaintenance.enabled?,
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
            conversion_id: conversion.id,
            fixture_key: company.test_workspace_manifest["demo_fixture_key"],
            employee_account_links_reverted: links_updated
          }
        )

        Result.new(
          dry_run: false,
          conversion_id: conversion.id,
          company_id: company.id,
          links_reverted: links_updated
        )
      end

      TenantSubdomainRegistry.invalidate!
      result
    end
  end
end
