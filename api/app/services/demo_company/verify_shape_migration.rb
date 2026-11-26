# frozen_string_literal: true

require "digest"
require "json"

module DemoCompany
  # Read-only before/after verification tool for the Track B demo-shape migration.
  #
  # Always refuses to run inside an existing database transaction and executes
  # inside its own `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY`
  # transaction using strictly read-only model/service predicates (no
  # early-access window retirements, no practice-account deactivations, no
  # Year-End job enqueues).
  #
  # Captures a deterministic, PII-free snapshot per named company covering:
  # - shape columns (the ONLY section allowed to differ between before and after;
  #   migration_rehearsal_error is emitted only as presence + digest, never raw text);
  # - logins and their access;
  # - employee-app links and their status;
  # - subdomain resolution;
  # - employee app readiness and switch state;
  # - firm counters (inbox, year-end, invoices/revenue exclusion, shared-email
  #   exclusion, client caps);
  # - EIN uniqueness;
  # - checksums of all payroll figures (pay periods, payroll items,
  #   CalculationSnapshot, PayrollItemLegacyDispositionService, paid-correction
  #   financial links & payment evidence, time-tracking history inventory, YTD
  #   totals, historical paychecks/balances, and posted EmployeeDocument records
  #   plus PayStubGenerator fingerprint stability).
  #
  # Diffing `before` against `after` fails closed on missing/malformed snapshots,
  # empty company sets, duplicate snapshots (unless allow_already_converted: true
  # for an already-converted retry), missing fields/link maps, unexpected
  # time-tracking history rows, or any non-shape difference.
  class VerifyShapeMigration
    class Error < StandardError; end

    DiffResult = Data.define(:passed, :company_ids, :shape_changes, :unexpected_diffs) do
      def passed?
        passed
      end
    end

    SCHEMA_VERSION = 1

    REQUIRED_SECTIONS = %w[
      shape identity logins employee_account_links subdomain employee_app
      counters ein_uniqueness payroll_checksums
    ].freeze

    SHA256_REGEX = /\A[0-9a-f]{64}\z/

    PAID_CORRECTION_COUNT_KEYS = %w[
      financial_correction_links
      correction_dispositions
      correction_receipts
      check_events
      check_reconciliation_events
      direct_deposit_payment_confirmations
      non_employee_check_supersessions
    ].freeze

    REQUIRED_SHAPE_COMPANY_KEYS = %w[
      demo
      payroll_environment
      test_workspace_purpose
      migration_rehearsal_status
      migration_rehearsal_created_by_id
      migration_rehearsal_created_at
      migration_rehearsal_created_at_present
      migration_rehearsal_completed_at
      migration_rehearsal_completed_at_present
      migration_rehearsal_error_present
      migration_rehearsal_error_sha256
      migration_source_company_id
      migration_source_batch_id
      test_workspace_expires_at_present
      test_workspace_archived_at_present
      test_workspace_sealed_at_present
    ].freeze

    def self.capture(organization:, actor:, company_ids:, tax_year: PayrollBusinessClock.today.year,
                     check_employee_service: false, readiness_database_state: nil, readiness_ping: nil)
      new(
        organization: organization,
        actor: actor,
        company_ids: company_ids,
        tax_year: tax_year,
        check_employee_service: check_employee_service,
        readiness_database_state: readiness_database_state,
        readiness_ping: readiness_ping
      ).capture
    end

    def self.diff(before_snapshot, after_snapshot, expected_company_ids: nil, allow_already_converted: false)
      before = stringify_deep(before_snapshot)
      after = stringify_deep(after_snapshot)

      unexpected = []
      shape_changes = {}

      validate_envelope("before", before, unexpected)
      validate_envelope("after", after, unexpected)

      if before.is_a?(Hash) && after.is_a?(Hash)
        %w[schema_version organization_id tax_year].each do |field|
          next if before[field] == after[field]

          unexpected << { path: field, before: before[field], after: after[field] }
        end
      end

      before_companies = before.is_a?(Hash) && before["companies"].is_a?(Hash) ? before["companies"] : {}
      after_companies = after.is_a?(Hash) && after["companies"].is_a?(Hash) ? after["companies"] : {}

      if before_companies.empty?
        unexpected << { path: "before.companies", expected: "non-empty hash", after: before_companies }
      end
      if after_companies.empty?
        unexpected << { path: "after.companies", expected: "non-empty hash", after: after_companies }
      end

      expected_keys = normalize_expected_ids(expected_company_ids, unexpected)
      if expected_keys
        if before_companies.keys.sort != expected_keys
          unexpected << { path: "before.companies", expected: expected_keys, after: before_companies.keys.sort }
        end
        if after_companies.keys.sort != expected_keys
          unexpected << { path: "after.companies", expected: expected_keys, after: after_companies.keys.sort }
        end
      elsif before_companies.keys.sort != after_companies.keys.sort
        unexpected << { path: "companies", before: before_companies.keys.sort, after: after_companies.keys.sort }
      end

      target_keys = expected_keys || (before_companies.keys | after_companies.keys).sort_by(&:to_i)

      target_keys.each do |cid|
        b_entry = before_companies[cid]
        a_entry = after_companies[cid]
        unless b_entry.is_a?(Hash)
          unexpected << { path: "before.companies.#{cid}", expected: "hash", after: b_entry }
        end
        unless a_entry.is_a?(Hash)
          unexpected << { path: "after.companies.#{cid}", expected: "hash", after: a_entry }
        end
        next unless b_entry.is_a?(Hash) && a_entry.is_a?(Hash)

        missing_before = REQUIRED_SECTIONS - b_entry.keys
        missing_after = REQUIRED_SECTIONS - a_entry.keys
        unexpected << { path: "before.companies.#{cid}.sections", expected: REQUIRED_SECTIONS, after: b_entry.keys.sort } if missing_before.any?
        unexpected << { path: "after.companies.#{cid}.sections", expected: REQUIRED_SECTIONS, after: a_entry.keys.sort } if missing_after.any?
        next if missing_before.any? || missing_after.any?

        validate_company_transition(cid, b_entry, a_entry, allow_already_converted: allow_already_converted, unexpected: unexpected)
        org_id = before["organization_id"]
        validate_company_sections(cid, "before", b_entry, organization_id: org_id, unexpected: unexpected)
        validate_company_sections(cid, "after", a_entry, organization_id: org_id, unexpected: unexpected)

        shape_changes[cid] = collect_diffs(b_entry["shape"], a_entry["shape"], prefix: "companies.#{cid}.shape")

        b_invariant = b_entry.except("shape")
        a_invariant = a_entry.except("shape")
        unexpected.concat(collect_diffs(b_invariant, a_invariant, prefix: "companies.#{cid}"))
      end

      DiffResult.new(
        passed: unexpected.empty?,
        company_ids: target_keys.map(&:to_i),
        shape_changes: shape_changes,
        unexpected_diffs: unexpected
      )
    end

    def initialize(organization:, actor:, company_ids:, tax_year: PayrollBusinessClock.today.year,
                   check_employee_service: false, readiness_database_state: nil, readiness_ping: nil)
      @organization = organization
      @actor = actor
      @company_ids = normalize_ids(company_ids)
      @tax_year = Integer(tax_year.to_s, 10)
      @check_employee_service = check_employee_service ? true : false
      @readiness_database_state = readiness_database_state
      @readiness_ping = readiness_ping
    end

    def capture
      ensure_no_open_transaction!
      system_scope do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
          authorize!
          TenantSubdomainRegistry.invalidate!
          companies = load_companies!
          org_counters = capture_org_counters(companies)

          {
            "schema_version" => SCHEMA_VERSION,
            "organization_id" => organization.id,
            "tax_year" => tax_year,
            "companies" => companies.each_with_object({}) do |company, map|
              map[company.id.to_s] = capture_company(company, org_counters: org_counters)
            end
          }
        end
      end
    end

    private

    attr_reader :organization, :actor, :company_ids, :tax_year, :check_employee_service,
                :readiness_database_state, :readiness_ping

    def ensure_no_open_transaction!
      return unless ApplicationRecord.connection.open_transactions.positive?

      raise Error, "Cannot run shape verification inside an existing database transaction"
    end

    def normalize_ids(raw)
      values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
      raise Error, "Specify COMPANY_IDS (comma-separated company IDs)" if values.empty?

      values.map { |value| Integer(value, 10) }.uniq.sort
    rescue ArgumentError
      raise Error, "Company IDs must be integers"
    end

    def authorize!
      allowed = organization.present? && actor&.organization_admin? &&
        actor.payroll_access_allowed?(deactivate_closed_practice: false) &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Error, "An organization administrator is required" unless allowed
    end

    def system_scope(&)
      TenantScope.current ? yield : TenantScope.as_system(reason: "Verify demo company shape migration", &)
    end

    def load_companies!
      found = Company.where(organization_id: organization.id, id: company_ids).order(:id).to_a
      missing = company_ids - found.map(&:id)
      raise Error, "Company ID(s) not found in organization: #{missing.join(', ')}" if missing.any?

      found
    end

    def capture_org_counters(companies)
      inbox_query = ClientInboxQuery.new(user: actor)
      inbox_company_ids = inbox_query.companies.pluck(:id).to_set
      year_end = YearEnd::ClientsOverview.new(user: actor, year: tax_year, enqueue_missing_checks: false).call
      shared_email_report = EmployeeContactHygiene::SharedEmailReport.new(actor: actor, organization_id: organization.id).call
      revenue_by_book = organization.finance_books.order(:id).map do |book|
        rows = InvoiceServiceFeeRevenue.call(finance_book: book, live_clients_only: true)
        {
          "finance_book_id" => book.id,
          "live_client_ids" => rows.filter_map { |row| row[:company_id] }.uniq.sort,
          "total_amount" => rows.sum(BigDecimal("0")) { |row| row[:amount].to_d }.to_s("F")
        }
      end

      {
        "client_limit" => organization.client_limit,
        "live_payroll_count" => organization.companies.live_payroll.count,
        "demo_count" => organization.companies.demo.count,
        "operating_count" => organization.companies.operating.count,
        "contained_count" => organization.companies.contained.count,
        "inbox_summary" => stringify_deep(inbox_query.summary),
        "inbox_company_ids" => inbox_company_ids,
        "year_end_counts" => stringify_deep(year_end.fetch(:counts)),
        "year_end_hidden" => stringify_deep(year_end.fetch(:hidden)),
        "year_end_clients_by_id" => year_end.fetch(:clients).index_by { |row| row[:company_id] },
        "shared_email_company_ids" => Array(shared_email_report[:companies]).map { |row| row[:company_id] }.to_set,
        "revenue_by_book" => revenue_by_book,
        "company_ids" => companies.map(&:id)
      }
    end

    def capture_company(company, org_counters:)
      {
        "shape" => capture_shape(company),
        "identity" => capture_identity(company),
        "logins" => capture_logins(company),
        "employee_account_links" => capture_links(company),
        "subdomain" => capture_subdomain(company),
        "employee_app" => capture_employee_app(company),
        "counters" => capture_company_counters(company, org_counters),
        "ein_uniqueness" => capture_ein_uniqueness(company),
        "payroll_checksums" => capture_payroll_checksums(company)
      }
    end

    def capture_shape(company)
      links_env = EmployeeAccountLink.where(company_id: company.id).order(:id).pluck(:id, :payroll_environment)
        .to_h { |id, env| [ id.to_s, env ] }
      error_text = company.migration_rehearsal_error
      {
        "company" => {
          "demo" => company[:demo] == true,
          "payroll_environment" => company.payroll_environment,
          "test_workspace_purpose" => company.test_workspace_purpose,
          "migration_rehearsal_status" => company.migration_rehearsal_status,
          "migration_rehearsal_created_by_id" => company.migration_rehearsal_created_by_id,
          "migration_rehearsal_created_at" => company.migration_rehearsal_created_at&.utc&.iso8601(6),
          "migration_rehearsal_created_at_present" => company.migration_rehearsal_created_at.present?,
          "migration_rehearsal_completed_at" => company.migration_rehearsal_completed_at&.utc&.iso8601(6),
          "migration_rehearsal_completed_at_present" => company.migration_rehearsal_completed_at.present?,
          "migration_rehearsal_error_present" => error_text.present?,
          "migration_rehearsal_error_sha256" => error_text.present? ? Digest::SHA256.hexdigest(error_text.to_s) : nil,
          "migration_source_company_id" => company.migration_source_company_id,
          "migration_source_batch_id" => company.migration_source_batch_id,
          "test_workspace_expires_at_present" => company.test_workspace_expires_at.present?,
          "test_workspace_archived_at_present" => company.test_workspace_archived_at.present?,
          "test_workspace_sealed_at_present" => company.test_workspace_sealed_at.present?
        },
        "employee_account_links_payroll_environments" => links_env
      }
    end

    def capture_identity(company)
      {
        "company_id" => company.id,
        "organization_id" => company.organization_id,
        "active" => company.active?,
        "demo_predicate" => company.demo?,
        "live_payroll_predicate" => company.live_payroll?,
        "operating_predicate" => company.operating?,
        "contained_predicate" => company.contained?,
        "practice_copy_predicate" => company.practice_copy?,
        "demo_fixture_key" => company.test_workspace_manifest.to_h["demo_fixture_key"],
        "demo_manifest_sha256" => sha256_canonical(company.test_workspace_manifest.to_h)
      }
    end

    def capture_logins(company)
      assigned_ids = CompanyAssignment.where(company_id: company.id).pluck(:user_id)
      linked_ids = EmployeeAccountLink.where(company_id: company.id).where.not(user_id: nil).pluck(:user_id)
      home_ids = User.where(company_id: company.id).pluck(:id)
      user_ids = (assigned_ids + linked_ids + home_ids + [ actor.id ]).uniq.sort

      assignments_by_user = CompanyAssignment.where(company_id: company.id, user_id: user_ids).index_by(&:user_id)
      User.where(id: user_ids).order(:id).map do |user|
        assignment = assignments_by_user[user.id]
        {
          "user_id" => user.id,
          "role" => user.role,
          "active" => user.active?,
          "invitation_status" => user.invitation_status,
          "company_id" => user.company_id,
          "practice_company_id" => user.practice_company_id,
          "payroll_access_allowed" => user.payroll_access_allowed?(deactivate_closed_practice: false),
          "can_access_company" => user.can_access_company?(company.id),
          "accessible_company_ids" => user.accessible_company_ids.sort,
          "assignment" => assignment ? {
            "exists" => true,
            "expired" => assignment.expired?,
            "client_management" => assignment.client_management?,
            "workspace_access_level" => assignment.workspace_access_level
          } : nil
        }
      end
    end

    def capture_links(company)
      links = EmployeeAccountLink.where(company_id: company.id).order(:id).map do |link|
        {
          "id" => link.id,
          "employee_id" => link.employee_id,
          "user_id" => link.user_id,
          "status" => link.status,
          "portal_eligible" => EmployeeAccountLink.portal_eligible.where(id: link.id).exists?,
          "invite_delivery" => link.invite_delivery,
          "invite_generation" => link.invite_generation,
          "activation_notice_status" => link.activation_notice_status,
          "activation_locked" => link.activation_locked?,
          "sign_up_reset_pending" => link.sign_up_reset_pending?,
          "profile_access_open" => link.profile_access_open?,
          "activated_at_present" => link.activated_at.present?,
          "former_at_present" => link.former_at.present?,
          "revoked_at_present" => link.revoked_at.present?
        }
      end

      {
        "portal_enabled_for_company" => EmployeeAccountLink.portal_enabled_for?(company, retire_windows: false),
        "count" => links.size,
        "status_counts" => links.group_by { |row| row["status"] }.transform_values(&:size).sort.to_h,
        "links" => links
      }
    end

    def capture_subdomain(company)
      slug = company.subdomain_slug
      origin = slug.present? ? TenantSubdomainRegistry.tenant_origin(slug) : nil
      branding = slug.present? ? TenantSubdomainRegistry.branding_for(slug: slug) : nil
      {
        "subdomain_slug" => slug,
        "tenant_origin" => origin,
        "enabled_origin_company_id" => origin ? TenantSubdomainRegistry.enabled_origin_company_id(origin) : nil,
        "branding_resolved" => branding.present?,
        "branding_demo" => branding&.dig(:demo),
        "branding_sha256" => branding ? sha256_canonical(branding) : nil
      }
    end

    def capture_employee_app(company)
      ping_proc = if readiness_ping
        readiness_ping
      elsif check_employee_service
        -> { EmployeeAppSwitch::Readiness.ping_employee_service(ENV) }
      else
        -> { { configured: false, ok: false, observation: nil, attestation_error: :not_configured } }
      end

      db_state_proc = readiness_database_state || -> { EmployeeAppSwitch::Readiness.database_state }
      readiness = EmployeeAppSwitch::Readiness.new(
        company: company,
        database_state: db_state_proc,
        ping: ping_proc,
        retire_windows: false
      )
      readiness_json = stringify_deep(readiness.as_json)
      # Strip volatile wall-clock timestamps so before/after diffs only flag real state drift.
      readiness_json.delete("checked_at")
      readiness_json["observed"]&.delete("observed_at")

      {
        "eligible_company" => EmployeeAppSwitch.eligible_company?(company),
        "stored_values" => stringify_deep(EmployeeAppSwitch.stored_values(company)),
        "switched_on_values" => stringify_deep(EmployeeAppSwitch.switched_on_values(company)),
        "effective_values" => stringify_deep(EmployeeAppSwitch.effective_values(company, retire_windows: false)),
        "on_anywhere" => EmployeeAppSwitch.on_anywhere(company).sort,
        "open_activations" => EmployeeAppActivation.open_parts_for(company.id).sort,
        "readiness" => readiness_json
      }
    end

    def capture_company_counters(company, org_counters)
      ye_row = org_counters.fetch("year_end_clients_by_id")[company.id]
      inbox_rows = ClientInboxQuery.new(user: actor, params: { company_id: company.id, per_page: 100 }).page.fetch(:data)

      {
        "client_caps" => {
          "client_limit" => org_counters.fetch("client_limit"),
          "organization_live_payroll_count" => org_counters.fetch("live_payroll_count"),
          "organization_demo_count" => org_counters.fetch("demo_count"),
          "organization_operating_count" => org_counters.fetch("operating_count"),
          "organization_contained_count" => org_counters.fetch("contained_count"),
          "in_live_payroll_scope" => organization.companies.live_payroll.where(id: company.id).exists?,
          "in_demo_scope" => organization.companies.demo.where(id: company.id).exists?,
          "in_operating_scope" => organization.companies.operating.where(id: company.id).exists?,
          "in_contained_scope" => organization.companies.contained.where(id: company.id).exists?
        },
        "inbox" => {
          "organization_summary" => org_counters.fetch("inbox_summary"),
          "company_visible_in_inbox" => org_counters.fetch("inbox_company_ids").include?(company.id),
          "company_row_count" => inbox_rows.size,
          "company_rows_demo_flags" => inbox_rows.map { |row| row[:demo] }.uniq.sort_by(&:to_s)
        },
        "year_end" => {
          "organization_counts" => org_counters.fetch("year_end_counts"),
          "organization_hidden" => org_counters.fetch("year_end_hidden"),
          "listed" => ye_row.present?,
          "demo_flag" => ye_row&.dig(:demo),
          "status" => ye_row&.dig(:status),
          "issue_codes" => Array(ye_row&.dig(:issues)).map { |issue| issue[:code] }.sort
        },
        "invoices_revenue" => {
          "books" => org_counters.fetch("revenue_by_book").map do |book|
            book.merge("company_excluded_from_live_revenue" => !book.fetch("live_client_ids").include?(company.id))
          end
        },
        "shared_email_report" => {
          "company_excluded" => !org_counters.fetch("shared_email_company_ids").include?(company.id)
        }
      }
    end

    def capture_ein_uniqueness(company)
      in_live_index = ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array([
          "SELECT EXISTS (SELECT 1 FROM companies WHERE id = ? AND payroll_environment = 'live' AND NOT demo)",
          company.id
        ])
      )
      live_sharing_ein = if company.ein.present?
        Company.live_payroll.where(ein: company.ein).order(:id).pluck(:id)
      else
        []
      end

      {
        "ein_present" => company.ein.present?,
        "in_live_ein_unique_index" => ActiveModel::Type::Boolean.new.cast(in_live_index),
        "live_company_ids_sharing_ein" => live_sharing_ein
      }
    end

    def capture_payroll_checksums(company)
      periods = PayPeriod.where(company_id: company.id).order(:id).to_a
      items = PayrollItem.where(company_id: company.id)
        .includes(:pay_period, :payroll_item_earnings, :payroll_item_deductions, :payroll_item_field_entries)
        .order(:id).to_a

      calculation_snapshots = periods.map do |period|
        [ period.id, PayrollReview::CalculationSnapshot.new(pay_period: period).call.fetch(:checksum) ]
      end

      committed_items = items.select { |item| item.pay_period&.committed? }
      legacy_disposition_digests = committed_items.map do |item|
        [ item.id, PayrollItemLegacyDispositionService.digest_for(item) ]
      end

      item_rows = items.map do |item|
        {
          "item" => normalize_attributes(item.attributes.except("updated_at")),
          "earnings" => item.payroll_item_earnings.sort_by(&:id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
          "deductions" => item.payroll_item_deductions.sort_by(&:id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
          "field_entries" => item.payroll_item_field_entries.sort_by(&:id).map { |r| normalize_attributes(r.attributes.except("updated_at")) }
        }
      end

      ytd_payload = {
        "company_ytd_totals" => CompanyYtdTotal.where(company_id: company.id).order(:year, :id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "employee_ytd_totals" => EmployeeYtdTotal.where(company_id: company.id).order(:year, :employee_id, :id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "department_ytd_totals" => DepartmentYtdTotal.where(company_id: company.id).order(:year, :department_id, :id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "historical_employee_ytd_balances" => HistoricalEmployeeYtdBalance.where(company_id: company.id).order(:id).map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "historical_paychecks" => HistoricalPaycheck.where(company_id: company.id).order(:id).map { |r| normalize_attributes(r.attributes.except("updated_at")) }
      }

      paid_correction_links = TimeTrackingFinancialCorrectionLink.where(company_id: company.id).order(:id).to_a
      paid_correction_dispositions = TimeTrackingCorrectionDisposition.where(company_id: company.id).order(:id).to_a
      paid_correction_receipts = TimeTrackingCorrectionReceipt
        .joins(:time_tracking_correction_disposition)
        .where(time_tracking_correction_dispositions: { company_id: company.id })
        .order(:id).to_a
      check_events = CheckEvent.where(company_id: company.id).order(:id).to_a
      check_reconciliations = CheckReconciliationEvent.where(company_id: company.id).order(:id).to_a
      dd_confirmations = DirectDepositPaymentConfirmation.where(company_id: company.id).order(:id).to_a
      check_supersessions = NonEmployeeCheckSupersession.where(company_id: company.id).order(:id).to_a

      paid_correction_payload = {
        "financial_correction_links" => paid_correction_links.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "correction_dispositions" => paid_correction_dispositions.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "correction_receipts" => paid_correction_receipts.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "check_events" => check_events.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "check_reconciliation_events" => check_reconciliations.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "direct_deposit_payment_confirmations" => dd_confirmations.map { |r| normalize_attributes(r.attributes.except("updated_at")) },
        "non_employee_check_supersessions" => check_supersessions.map { |r| normalize_attributes(r.attributes.except("updated_at")) }
      }

      tt_sources = TimeTrackingSource.where(company_id: company.id).order(:id).pluck(:id)
      tt_imports = TimeTrackingImport.where(company_id: company.id).order(:id).pluck(:id)
      history_reviews = AireHistoryReview.where(company_id: company.id).order(:id).pluck(:id, :digest)
      history_receipts = AireVerifiedHistoryRolloutReceipt.where(company_id: company.id).order(:id).pluck(:id, :manifest_sha256)

      documents = EmployeeDocument.where(company_id: company.id).includes(payroll_item: [ :employee, :pay_period ]).order(:id).to_a
      document_rows = documents.map do |doc|
        {
          "id" => doc.id,
          "payroll_item_id" => doc.payroll_item_id,
          "historical_paycheck_id" => doc.historical_paycheck_id,
          "employee_id" => doc.employee_id,
          "tax_year" => doc.tax_year,
          "revision" => doc.revision,
          "status" => doc.status,
          "sha256" => doc.sha256,
          "payroll_facts_sha256" => doc.payroll_facts_sha256,
          "payment_line" => doc.payment_line,
          "corrected" => doc.corrected,
          "replaces_document_id" => doc.replaces_document_id,
          "storage_key" => doc.storage_key
        }
      end

      posted_stub_fingerprint_matches = documents.select { |doc| doc.posted? && doc.payroll_item_id.present? }.map do |doc|
        gen = PayStubGenerator.new(doc.payroll_item, employee_copy: true)
        {
          "document_id" => doc.id,
          "payroll_item_id" => doc.payroll_item_id,
          "current_fingerprint" => gen.employee_payroll_facts_sha256,
          "matches_stored" => gen.matches_employee_payroll_facts?(doc.payroll_facts_sha256)
        }
      end

      {
        "pay_periods_count" => periods.size,
        "pay_periods_sha256" => sha256_canonical(periods.map { |p| normalize_attributes(p.attributes.except("updated_at")) }),
        "payroll_items_count" => items.size,
        "payroll_items_sha256" => sha256_canonical(item_rows),
        "calculation_snapshots_sha256" => sha256_canonical(calculation_snapshots),
        "legacy_disposition_digests_sha256" => sha256_canonical(legacy_disposition_digests),
        "paid_correction_evidence_counts" => paid_correction_payload.transform_values(&:size),
        "paid_correction_evidence_sha256" => sha256_canonical(paid_correction_payload),
        "time_tracking_history" => {
          "sources_count" => tt_sources.size,
          "imports_count" => tt_imports.size,
          "history_reviews_count" => history_reviews.size,
          "verified_history_receipts_count" => history_receipts.size,
          "sha256" => sha256_canonical(
            "sources" => tt_sources,
            "imports" => tt_imports,
            "history_reviews" => history_reviews,
            "verified_history_receipts" => history_receipts
          )
        },
        "ytd_totals_sha256" => sha256_canonical(ytd_payload),
        "posted_documents_count" => documents.size,
        "posted_documents_sha256" => sha256_canonical(document_rows),
        "posted_stub_fingerprints_sha256" => sha256_canonical(posted_stub_fingerprint_matches),
        "all_posted_stubs_match_stored_fingerprint" => posted_stub_fingerprint_matches.all? { |row| row["matches_stored"] }
      }
    end

    def normalize_attributes(hash)
      hash.keys.map(&:to_s).sort.to_h { |k| [ k, normalize_value(hash[k]) ] }
    end

    def normalize_value(value)
      case value
      when BigDecimal then value.to_s("F")
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      when Hash then value.keys.map(&:to_s).sort.to_h { |k| [ k, normalize_value(value.key?(k) ? value[k] : value[k.to_sym]) ] }
      when Array then value.map { |item| normalize_value(item) }
      else value
      end
    end

    def sha256_canonical(value)
      Digest::SHA256.hexdigest(JSON.generate(normalize_value(value)))
    end

    def stringify_deep(value)
      self.class.stringify_deep(value)
    end

    class << self
      def stringify_deep(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h { |k| [ k, stringify_deep(value.key?(k) ? value[k] : value[k.to_sym]) ] }
        when Array
          value.map { |item| stringify_deep(item) }
        else
          value
        end
      end

      def collect_diffs(before_val, after_val, prefix:)
        return [] if before_val == after_val

        if before_val.is_a?(Hash) && after_val.is_a?(Hash)
          (before_val.keys | after_val.keys).sort.flat_map do |key|
            b_has = before_val.key?(key)
            a_has = after_val.key?(key)
            if b_has && a_has
              collect_diffs(before_val[key], after_val[key], prefix: "#{prefix}.#{key}")
            else
              [ {
                path: "#{prefix}.#{key}",
                before: b_has ? before_val[key] : :missing,
                after: a_has ? after_val[key] : :missing
              } ]
            end
          end
        else
          [ { path: prefix, before: before_val, after: after_val } ]
        end
      end

      def validate_envelope(label, snapshot, unexpected)
        unless snapshot.is_a?(Hash)
          unexpected << { path: label, expected: "hash", after: snapshot }
          return
        end

        unless snapshot["schema_version"] == SCHEMA_VERSION
          unexpected << { path: "#{label}.schema_version", expected: SCHEMA_VERSION, after: snapshot["schema_version"] }
        end
        unless snapshot["organization_id"].is_a?(Integer) && snapshot["organization_id"].positive?
          unexpected << { path: "#{label}.organization_id", expected: "positive integer", after: snapshot["organization_id"] }
        end
        unless snapshot["tax_year"].is_a?(Integer) && snapshot["tax_year"] >= 2020
          unexpected << { path: "#{label}.tax_year", expected: "tax year integer", after: snapshot["tax_year"] }
        end
        unless snapshot["companies"].is_a?(Hash)
          unexpected << { path: "#{label}.companies", expected: "hash", after: snapshot["companies"] }
        end
      end

      def normalize_expected_ids(raw, unexpected)
        return nil if raw.nil?

        values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
        if values.empty?
          unexpected << { path: "expected_company_ids", expected: "non-empty company IDs", after: raw }
          return []
        end

        values.map { |v| Integer(v, 10).to_s }.uniq.sort
      rescue ArgumentError
        unexpected << { path: "expected_company_ids", expected: "integer company IDs", after: raw }
        []
      end

      def validate_company_transition(cid, before_entry, after_entry, allow_already_converted:, unexpected:)
        before_shape = before_entry["shape"]
        after_shape = after_entry["shape"]

        before_ok = validate_shape_structure(cid, "before", before_shape, before_entry["employee_account_links"], unexpected)
        after_ok = validate_shape_structure(cid, "after", after_shape, after_entry["employee_account_links"], unexpected)
        return unless before_ok && after_ok

        before_is_legacy = legacy_shape?(before_shape)
        before_is_flag = flag_shape?(before_shape)
        after_is_flag = flag_shape?(after_shape)

        unless after_is_flag
          validate_flag_shape_fields(cid, "after", after_shape, unexpected)
        end

        if allow_already_converted
          unless before_is_legacy || before_is_flag
            unexpected << {
              path: "before.companies.#{cid}.shape",
              expected: "legacy-shape demo or already-converted flag-shape demo",
              after: before_shape["company"]
            }
          end
        elsif !before_is_legacy
          unexpected << {
            path: "before.companies.#{cid}.shape",
            expected: "legacy-shape demo (pass allow_already_converted: true only for an already-converted retry)",
            after: before_shape["company"]
          }
        end
      end

      def validate_shape_structure(cid, label, shape, links_section, unexpected)
        unless shape.is_a?(Hash)
          unexpected << { path: "#{label}.companies.#{cid}.shape", expected: "hash", after: shape }
          return false
        end

        company = shape["company"]
        links_env = shape["employee_account_links_payroll_environments"]
        ok = true

        unless company.is_a?(Hash)
          unexpected << { path: "#{label}.companies.#{cid}.shape.company", expected: "hash", after: company }
          ok = false
        else
          missing_keys = REQUIRED_SHAPE_COMPANY_KEYS - company.keys
          if missing_keys.any?
            unexpected << { path: "#{label}.companies.#{cid}.shape.company.keys", expected: REQUIRED_SHAPE_COMPANY_KEYS, after: company.keys.sort }
            ok = false
          end
        end

        unless links_env.is_a?(Hash)
          unexpected << { path: "#{label}.companies.#{cid}.shape.employee_account_links_payroll_environments", expected: "hash", after: links_env }
          ok = false
        else
          expected_link_ids = if links_section.is_a?(Hash) && links_section["links"].is_a?(Array)
            links_section["links"].map { |row| row.is_a?(Hash) ? row["id"].to_s : nil }.compact.sort
          else
            unexpected << { path: "#{label}.companies.#{cid}.employee_account_links.links", expected: "array", after: links_section }
            ok = false
            nil
          end
          if expected_link_ids && links_env.keys.sort != expected_link_ids
            unexpected << {
              path: "#{label}.companies.#{cid}.shape.employee_account_links_payroll_environments",
              expected: expected_link_ids,
              after: links_env.keys.sort
            }
            ok = false
          end
        end

        ok
      end

      def legacy_shape?(shape)
        company = shape["company"]
        links = shape["employee_account_links_payroll_environments"]
        company["demo"] == false &&
          company["payroll_environment"] == "migration_rehearsal" &&
          company["test_workspace_purpose"] == "demo" &&
          company["migration_rehearsal_status"] == "ready" &&
          company["migration_source_company_id"].nil? &&
          company["migration_source_batch_id"].nil? &&
          company["test_workspace_expires_at_present"] == false &&
          company["test_workspace_archived_at_present"] == false &&
          company["test_workspace_sealed_at_present"] == false &&
          links.values.all? { |env| env == "migration_rehearsal" }
      end

      def flag_shape?(shape)
        company = shape["company"]
        links = shape["employee_account_links_payroll_environments"]
        expected_flag_company_shape.all? { |field, expected| company[field] == expected } &&
          links.values.all? { |env| env == "live" }
      end

      def expected_flag_company_shape
        {
          "demo" => true,
          "payroll_environment" => "live",
          "test_workspace_purpose" => nil,
          "migration_rehearsal_status" => nil,
          "migration_rehearsal_created_by_id" => nil,
          "migration_rehearsal_created_at" => nil,
          "migration_rehearsal_created_at_present" => false,
          "migration_rehearsal_completed_at" => nil,
          "migration_rehearsal_completed_at_present" => false,
          "migration_rehearsal_error_present" => false,
          "migration_rehearsal_error_sha256" => nil,
          "migration_source_company_id" => nil,
          "migration_source_batch_id" => nil,
          "test_workspace_expires_at_present" => false,
          "test_workspace_archived_at_present" => false,
          "test_workspace_sealed_at_present" => false
        }
      end

      def validate_flag_shape_fields(cid, label, shape, unexpected)
        company = shape["company"]
        expected_flag_company_shape.each do |field, expected|
          actual = company[field]
          next if actual == expected

          unexpected << { path: "#{label}.companies.#{cid}.shape.company.#{field}", expected: expected, after: actual }
        end

        shape["employee_account_links_payroll_environments"].each do |link_id, env|
          next if env == "live"

          unexpected << {
            path: "#{label}.companies.#{cid}.shape.employee_account_links_payroll_environments.#{link_id}",
            expected: "live",
            after: env
          }
        end
      end

      def validate_company_sections(cid, label, entry, organization_id:, unexpected:)
        validate_identity_section(cid, label, entry["identity"], organization_id: organization_id, unexpected: unexpected)
        validate_logins_section(cid, label, entry["logins"], unexpected: unexpected)
        validate_links_section(cid, label, entry["employee_account_links"], unexpected: unexpected)
        validate_subdomain_section(cid, label, entry["subdomain"], unexpected: unexpected)
        validate_employee_app_section(cid, label, entry["employee_app"], unexpected: unexpected)
        validate_counters_section(cid, label, entry["counters"], unexpected: unexpected)
        validate_ein_section(cid, label, entry["ein_uniqueness"], unexpected: unexpected)
        validate_payroll_checksums_section(cid, label, entry["payroll_checksums"], unexpected: unexpected)
      end

      def validate_identity_section(cid, label, identity, organization_id:, unexpected:)
        prefix = "#{label}.companies.#{cid}.identity"
        unless identity.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: identity }
          return
        end

        expect_eq(prefix, "company_id", identity["company_id"], cid.to_i, unexpected)
        expect_eq(prefix, "organization_id", identity["organization_id"], organization_id, unexpected) if organization_id.is_a?(Integer)
        expect_bool(prefix, "active", identity["active"], unexpected)
        expect_eq(prefix, "demo_predicate", identity["demo_predicate"], true, unexpected)
        expect_eq(prefix, "live_payroll_predicate", identity["live_payroll_predicate"], false, unexpected)
        expect_bool(prefix, "operating_predicate", identity["operating_predicate"], unexpected)
        expect_eq(prefix, "contained_predicate", identity["contained_predicate"], true, unexpected)
        expect_eq(prefix, "practice_copy_predicate", identity["practice_copy_predicate"], false, unexpected)
        expect_key(prefix, "demo_fixture_key", identity, unexpected)
        expect_sha256(prefix, "demo_manifest_sha256", identity["demo_manifest_sha256"], unexpected)
      end

      def validate_logins_section(cid, label, logins, unexpected:)
        prefix = "#{label}.companies.#{cid}.logins"
        unless logins.is_a?(Array) && logins.any?
          unexpected << { path: prefix, expected: "non-empty array", after: logins }
          return
        end

        logins.each_with_index do |row, idx|
          row_prefix = "#{prefix}[#{idx}]"
          unless row.is_a?(Hash)
            unexpected << { path: row_prefix, expected: "hash", after: row }
            next
          end
          expect_int(row_prefix, "user_id", row["user_id"], unexpected, min: 1)
          expect_non_empty_string(row_prefix, "role", row["role"], unexpected)
          expect_bool(row_prefix, "active", row["active"], unexpected)
          expect_key(row_prefix, "invitation_status", row, unexpected)
          expect_key(row_prefix, "company_id", row, unexpected)
          expect_key(row_prefix, "practice_company_id", row, unexpected)
          expect_bool(row_prefix, "payroll_access_allowed", row["payroll_access_allowed"], unexpected)
          expect_bool(row_prefix, "can_access_company", row["can_access_company"], unexpected)
          unless row["accessible_company_ids"].is_a?(Array) && row["accessible_company_ids"].all?(Integer)
            unexpected << { path: "#{row_prefix}.accessible_company_ids", expected: "array of integers", after: row["accessible_company_ids"] }
          end
          expect_key(row_prefix, "assignment", row, unexpected)
        end
      end

      def validate_links_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.employee_account_links"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        expect_bool(prefix, "portal_enabled_for_company", section["portal_enabled_for_company"], unexpected)
        expect_int(prefix, "count", section["count"], unexpected, min: 0)
        unless section["status_counts"].is_a?(Hash) && section["status_counts"].values.all? { |v| v.is_a?(Integer) && v >= 0 }
          unexpected << { path: "#{prefix}.status_counts", expected: "hash of non-negative integers", after: section["status_counts"] }
        end
        unless section["links"].is_a?(Array)
          unexpected << { path: "#{prefix}.links", expected: "array", after: section["links"] }
          return
        end

        if section["count"].is_a?(Integer) && section["links"].size != section["count"]
          unexpected << { path: "#{prefix}.count", expected: section["links"].size, after: section["count"] }
        end
        if section["status_counts"].is_a?(Hash) && section["status_counts"].values.all?(Integer) &&
          section["status_counts"].values.sum != section["links"].size
          unexpected << { path: "#{prefix}.status_counts", expected: "sum #{section['links'].size}", after: section["status_counts"] }
        end

        section["links"].each_with_index do |link, idx|
          link_prefix = "#{prefix}.links[#{idx}]"
          unless link.is_a?(Hash)
            unexpected << { path: link_prefix, expected: "hash", after: link }
            next
          end
          expect_int(link_prefix, "id", link["id"], unexpected, min: 1)
          expect_int(link_prefix, "employee_id", link["employee_id"], unexpected, min: 1)
          expect_key(link_prefix, "user_id", link, unexpected)
          expect_non_empty_string(link_prefix, "status", link["status"], unexpected)
          expect_bool(link_prefix, "portal_eligible", link["portal_eligible"], unexpected)
          expect_key(link_prefix, "invite_delivery", link, unexpected)
          expect_int(link_prefix, "invite_generation", link["invite_generation"], unexpected, min: 0)
          expect_key(link_prefix, "activation_notice_status", link, unexpected)
          %w[activation_locked sign_up_reset_pending profile_access_open activated_at_present former_at_present revoked_at_present].each do |flag|
            expect_bool(link_prefix, flag, link[flag], unexpected)
          end
        end
      end

      def validate_subdomain_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.subdomain"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        %w[subdomain_slug tenant_origin enabled_origin_company_id branding_demo branding_sha256].each do |key|
          expect_key(prefix, key, section, unexpected)
        end
        expect_bool(prefix, "branding_resolved", section["branding_resolved"], unexpected)
        if section["branding_sha256"].present?
          expect_sha256(prefix, "branding_sha256", section["branding_sha256"], unexpected)
        end
      end

      def validate_employee_app_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.employee_app"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        expect_bool(prefix, "eligible_company", section["eligible_company"], unexpected)
        %w[stored_values switched_on_values effective_values].each do |key|
          unless section[key].is_a?(Hash) && section[key].any?
            unexpected << { path: "#{prefix}.#{key}", expected: "non-empty hash", after: section[key] }
          end
        end
        %w[on_anywhere open_activations].each do |key|
          unless section[key].is_a?(Array)
            unexpected << { path: "#{prefix}.#{key}", expected: "array", after: section[key] }
          end
        end

        readiness = section["readiness"]
        unless readiness.is_a?(Hash)
          unexpected << { path: "#{prefix}.readiness", expected: "hash", after: readiness }
          return
        end
        unless readiness["checks"].is_a?(Array) && readiness["checks"].any?
          unexpected << { path: "#{prefix}.readiness.checks", expected: "non-empty array", after: readiness["checks"] }
        end
        %w[counsel_checks switch_checks observed database].each do |key|
          unless readiness[key].is_a?(Hash)
            unexpected << { path: "#{prefix}.readiness.#{key}", expected: "hash", after: readiness[key] }
          end
        end
        expect_key("#{prefix}.readiness", "early_access", readiness, unexpected)
      end

      def validate_counters_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.counters"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        caps = section["client_caps"]
        if caps.is_a?(Hash)
          expect_key("#{prefix}.client_caps", "client_limit", caps, unexpected)
          expect_int("#{prefix}.client_caps", "organization_live_payroll_count", caps["organization_live_payroll_count"], unexpected, min: 0)
          expect_int("#{prefix}.client_caps", "organization_demo_count", caps["organization_demo_count"], unexpected, min: 1)
          expect_int("#{prefix}.client_caps", "organization_operating_count", caps["organization_operating_count"], unexpected, min: 0)
          expect_int("#{prefix}.client_caps", "organization_contained_count", caps["organization_contained_count"], unexpected, min: 1)
          expect_eq("#{prefix}.client_caps", "in_live_payroll_scope", caps["in_live_payroll_scope"], false, unexpected)
          expect_eq("#{prefix}.client_caps", "in_demo_scope", caps["in_demo_scope"], true, unexpected)
          expect_bool("#{prefix}.client_caps", "in_operating_scope", caps["in_operating_scope"], unexpected)
          expect_eq("#{prefix}.client_caps", "in_contained_scope", caps["in_contained_scope"], true, unexpected)
        else
          unexpected << { path: "#{prefix}.client_caps", expected: "hash", after: caps }
        end

        inbox = section["inbox"]
        if inbox.is_a?(Hash)
          unless inbox["organization_summary"].is_a?(Hash) && inbox["organization_summary"].any? && inbox["organization_summary"].values.all?(Integer)
            unexpected << { path: "#{prefix}.inbox.organization_summary", expected: "non-empty hash of integers", after: inbox["organization_summary"] }
          end
          expect_bool("#{prefix}.inbox", "company_visible_in_inbox", inbox["company_visible_in_inbox"], unexpected)
          expect_int("#{prefix}.inbox", "company_row_count", inbox["company_row_count"], unexpected, min: 0)
          unless inbox["company_rows_demo_flags"].is_a?(Array)
            unexpected << { path: "#{prefix}.inbox.company_rows_demo_flags", expected: "array", after: inbox["company_rows_demo_flags"] }
          end
        else
          unexpected << { path: "#{prefix}.inbox", expected: "hash", after: inbox }
        end

        year_end = section["year_end"]
        if year_end.is_a?(Hash)
          unless year_end["organization_counts"].is_a?(Hash) && year_end["organization_counts"].any? && year_end["organization_counts"].values.all?(Integer)
            unexpected << { path: "#{prefix}.year_end.organization_counts", expected: "non-empty hash of integers", after: year_end["organization_counts"] }
          end
          unless year_end["organization_hidden"].is_a?(Hash)
            unexpected << { path: "#{prefix}.year_end.organization_hidden", expected: "hash", after: year_end["organization_hidden"] }
          end
          expect_bool("#{prefix}.year_end", "listed", year_end["listed"], unexpected)
          expect_key("#{prefix}.year_end", "demo_flag", year_end, unexpected)
          expect_key("#{prefix}.year_end", "status", year_end, unexpected)
          unless year_end["issue_codes"].is_a?(Array)
            unexpected << { path: "#{prefix}.year_end.issue_codes", expected: "array", after: year_end["issue_codes"] }
          end
        else
          unexpected << { path: "#{prefix}.year_end", expected: "hash", after: year_end }
        end

        revenue = section["invoices_revenue"]
        if revenue.is_a?(Hash) && revenue["books"].is_a?(Array)
          revenue["books"].each_with_index do |book, idx|
            b_prefix = "#{prefix}.invoices_revenue.books[#{idx}]"
            unless book.is_a?(Hash)
              unexpected << { path: b_prefix, expected: "hash", after: book }
              next
            end
            expect_int(b_prefix, "finance_book_id", book["finance_book_id"], unexpected, min: 1)
            unless book["live_client_ids"].is_a?(Array) && book["live_client_ids"].all?(Integer)
              unexpected << { path: "#{b_prefix}.live_client_ids", expected: "array of integers", after: book["live_client_ids"] }
            end
            expect_non_empty_string(b_prefix, "total_amount", book["total_amount"], unexpected)
            expect_eq(b_prefix, "company_excluded_from_live_revenue", book["company_excluded_from_live_revenue"], true, unexpected)
          end
        else
          unexpected << { path: "#{prefix}.invoices_revenue.books", expected: "array", after: revenue }
        end

        shared = section["shared_email_report"]
        if shared.is_a?(Hash)
          expect_eq("#{prefix}.shared_email_report", "company_excluded", shared["company_excluded"], true, unexpected)
        else
          unexpected << { path: "#{prefix}.shared_email_report", expected: "hash", after: shared }
        end
      end

      def validate_ein_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.ein_uniqueness"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        expect_bool(prefix, "ein_present", section["ein_present"], unexpected)
        expect_eq(prefix, "in_live_ein_unique_index", section["in_live_ein_unique_index"], false, unexpected)
        unless section["live_company_ids_sharing_ein"].is_a?(Array) && section["live_company_ids_sharing_ein"].all?(Integer)
          unexpected << { path: "#{prefix}.live_company_ids_sharing_ein", expected: "array of integers", after: section["live_company_ids_sharing_ein"] }
        end
      end

      def validate_payroll_checksums_section(cid, label, section, unexpected:)
        prefix = "#{label}.companies.#{cid}.payroll_checksums"
        unless section.is_a?(Hash)
          unexpected << { path: prefix, expected: "hash", after: section }
          return
        end

        %w[pay_periods_count payroll_items_count posted_documents_count].each do |key|
          expect_int(prefix, key, section[key], unexpected, min: 0)
        end
        %w[
          pay_periods_sha256 payroll_items_sha256 calculation_snapshots_sha256
          legacy_disposition_digests_sha256 paid_correction_evidence_sha256
          ytd_totals_sha256 posted_documents_sha256 posted_stub_fingerprints_sha256
        ].each do |key|
          expect_sha256(prefix, key, section[key], unexpected)
        end
        expect_eq(prefix, "all_posted_stubs_match_stored_fingerprint", section["all_posted_stubs_match_stored_fingerprint"], true, unexpected)

        paid_counts = section["paid_correction_evidence_counts"]
        if paid_counts.is_a?(Hash)
          PAID_CORRECTION_COUNT_KEYS.each do |key|
            expect_int("#{prefix}.paid_correction_evidence_counts", key, paid_counts[key], unexpected, min: 0)
          end
        else
          unexpected << { path: "#{prefix}.paid_correction_evidence_counts", expected: "hash", after: paid_counts }
        end

        history = section["time_tracking_history"]
        unless history.is_a?(Hash)
          unexpected << { path: "#{prefix}.time_tracking_history", expected: "hash", after: history }
          return
        end

        %w[sources_count imports_count history_reviews_count verified_history_receipts_count].each do |key|
          expect_eq("#{prefix}.time_tracking_history", key, history[key], 0, unexpected)
        end
        expect_sha256("#{prefix}.time_tracking_history", "sha256", history["sha256"], unexpected)
      end

      def expect_key(prefix, key, hash, unexpected)
        return if hash.key?(key)

        unexpected << { path: "#{prefix}.#{key}", expected: "present", after: :missing }
      end

      def expect_eq(prefix, key, actual, expected, unexpected)
        return if actual == expected

        unexpected << { path: "#{prefix}.#{key}", expected: expected, after: actual }
      end

      def expect_bool(prefix, key, actual, unexpected)
        return if actual == true || actual == false

        unexpected << { path: "#{prefix}.#{key}", expected: "boolean", after: actual }
      end

      def expect_int(prefix, key, actual, unexpected, min: nil)
        return if actual.is_a?(Integer) && (min.nil? || actual >= min)

        unexpected << { path: "#{prefix}.#{key}", expected: min ? "integer >= #{min}" : "integer", after: actual }
      end

      def expect_non_empty_string(prefix, key, actual, unexpected)
        return if actual.is_a?(String) && !actual.empty?

        unexpected << { path: "#{prefix}.#{key}", expected: "non-empty string", after: actual }
      end

      def expect_sha256(prefix, key, actual, unexpected)
        return if actual.is_a?(String) && SHA256_REGEX.match?(actual)

        unexpected << { path: "#{prefix}.#{key}", expected: "64-hex sha256", after: actual }
      end
    end
  end
end
