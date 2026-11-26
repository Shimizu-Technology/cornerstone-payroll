# frozen_string_literal: true

require "digest"
require "json"

module DemoCompany
  # Read-only before/after verification tool for the Track B demo-shape migration.
  #
  # Captures a deterministic, PII-free snapshot per named company covering:
  # - shape columns (the ONLY section allowed to differ between before and after);
  # - logins and their access;
  # - employee-app links and their status;
  # - subdomain resolution;
  # - employee app readiness and switch state;
  # - firm counters (inbox, year-end, invoices/revenue exclusion, shared-email exclusion, client caps);
  # - EIN uniqueness;
  # - checksums of all payroll figures (pay periods, payroll items, CalculationSnapshot,
  #   PayrollItemLegacyDispositionService digests, YTD totals, historical paychecks/balances,
  #   and posted EmployeeDocument records plus PayStubGenerator fingerprint stability).
  #
  # Diffing `before` against `after` fails closed if ANY non-shape field changed
  # or if the shape transition did not produce a valid new-shape demo company.
  class VerifyShapeMigration
    class Error < StandardError; end

    DiffResult = Data.define(:passed, :company_ids, :shape_changes, :unexpected_diffs) do
      def passed?
        passed
      end
    end

    SCHEMA_VERSION = 1

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

    def self.diff(before_snapshot, after_snapshot)
      before = stringify_deep(before_snapshot)
      after = stringify_deep(after_snapshot)

      unexpected = []
      shape_changes = {}

      if before["schema_version"] != after["schema_version"]
        unexpected << { path: "schema_version", before: before["schema_version"], after: after["schema_version"] }
      end
      if before["organization_id"] != after["organization_id"]
        unexpected << { path: "organization_id", before: before["organization_id"], after: after["organization_id"] }
      end
      if before["tax_year"] != after["tax_year"]
        unexpected << { path: "tax_year", before: before["tax_year"], after: after["tax_year"] }
      end

      before_companies = before.fetch("companies", {})
      after_companies = after.fetch("companies", {})
      all_company_ids = (before_companies.keys | after_companies.keys).sort_by(&:to_i)

      if before_companies.keys.sort != after_companies.keys.sort
        unexpected << { path: "companies", before: before_companies.keys.sort, after: after_companies.keys.sort }
      end

      all_company_ids.each do |cid|
        b_entry = before_companies[cid]
        a_entry = after_companies[cid]
        next if b_entry.nil? || a_entry.nil?

        shape_changes[cid] = collect_diffs(b_entry["shape"], a_entry["shape"], prefix: "companies.#{cid}.shape")
        validate_after_shape(cid, a_entry["shape"], unexpected)

        b_invariant = b_entry.except("shape")
        a_invariant = a_entry.except("shape")
        unexpected.concat(collect_diffs(b_invariant, a_invariant, prefix: "companies.#{cid}"))
      end

      DiffResult.new(
        passed: unexpected.empty?,
        company_ids: all_company_ids.map(&:to_i),
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
      system_scope do
        authorize!
        with_read_only_if_top_level do
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

    def normalize_ids(raw)
      values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
      raise Error, "Specify COMPANY_IDS (comma-separated company IDs)" if values.empty?

      values.map { |value| Integer(value, 10) }.uniq.sort
    rescue ArgumentError
      raise Error, "Company IDs must be integers"
    end

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Error, "An organization administrator is required" unless allowed
    end

    def system_scope(&)
      TenantScope.current ? yield : TenantScope.as_system(reason: "Verify demo company shape migration", &)
    end

    def with_read_only_if_top_level(&)
      connection = ApplicationRecord.connection
      return yield if connection.open_transactions.positive?

      ApplicationRecord.transaction do
        connection.execute("SET TRANSACTION READ ONLY")
        yield
      end
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
      {
        "company" => {
          "demo" => company[:demo] == true,
          "payroll_environment" => company.payroll_environment,
          "test_workspace_purpose" => company.test_workspace_purpose,
          "migration_rehearsal_status" => company.migration_rehearsal_status,
          "migration_rehearsal_created_by_id" => company.migration_rehearsal_created_by_id,
          "migration_rehearsal_created_at_present" => company.migration_rehearsal_created_at.present?,
          "migration_rehearsal_completed_at_present" => company.migration_rehearsal_completed_at.present?,
          "migration_rehearsal_error" => company.migration_rehearsal_error,
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
        "demo_fixture_key" => company.test_workspace_manifest.to_h["demo_fixture_key"]
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
          "payroll_access_allowed" => user.payroll_access_allowed?,
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
        "portal_enabled_for_company" => EmployeeAccountLink.portal_enabled_for?(company),
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
        "effective_values" => stringify_deep(EmployeeAppSwitch.effective_values(company)),
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
            collect_diffs(before_val[key], after_val[key], prefix: "#{prefix}.#{key}")
          end
        else
          [ { path: prefix, before: before_val, after: after_val } ]
        end
      end

      def validate_after_shape(cid, shape, unexpected)
        company = shape.is_a?(Hash) ? shape["company"] : nil
        unless company.is_a?(Hash)
          unexpected << { path: "companies.#{cid}.shape.company", before: "present", after: company }
          return
        end

        expected_company_shape = {
          "demo" => true,
          "payroll_environment" => "live",
          "test_workspace_purpose" => nil,
          "migration_rehearsal_status" => nil,
          "migration_rehearsal_created_by_id" => nil,
          "migration_rehearsal_created_at_present" => false,
          "migration_rehearsal_completed_at_present" => false,
          "migration_rehearsal_error" => nil,
          "migration_source_company_id" => nil,
          "migration_source_batch_id" => nil,
          "test_workspace_expires_at_present" => false,
          "test_workspace_archived_at_present" => false,
          "test_workspace_sealed_at_present" => false
        }
        expected_company_shape.each do |field, expected|
          actual = company[field]
          next if actual == expected

          unexpected << { path: "companies.#{cid}.shape.company.#{field}", expected: expected, after: actual }
        end

        links = shape["employee_account_links_payroll_environments"]
        if links.is_a?(Hash)
          links.each do |link_id, env|
            next if env == "live"

            unexpected << {
              path: "companies.#{cid}.shape.employee_account_links_payroll_environments.#{link_id}",
              expected: "live",
              after: env
            }
          end
        end
      end
    end
  end
end
