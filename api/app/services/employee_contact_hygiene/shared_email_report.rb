# frozen_string_literal: true

require "set"

module EmployeeContactHygiene
  class SharedEmailReport
    def initialize(actor:, organization_id:, company_id: nil)
      @actor = actor
      @organization_id = organization_id
      @company_id = company_id
    end

    def call
      configurable_companies = all_configurable_companies
      return empty_report if configurable_companies.empty?

      target_companies = if @company_id.present?
        configurable_companies.select { |company| company.id == @company_id.to_i }
      else
        configurable_companies
      end
      return empty_report if target_companies.empty?

      configurable_ids = configurable_companies.map(&:id)
      target_ids = target_companies.map(&:id)
      company_by_id = target_companies.index_by(&:id)
      org_id = @organization_id || configurable_companies.first.organization_id

      configured_placeholders = EmployeeContactValidator.configured_placeholder_emails
      db_marked_placeholders = EmployeeContactValidator.db_marked_placeholder_emails(org_id)
      marked_placeholders = configured_placeholders | db_marked_placeholders

      # Aggregate counts strictly scoped to companies this staff user can configure (no PII).
      accessible_stats = aggregate_accessible_email_stats(configurable_ids)

      # Per-company aggregate counts (no PII — only company_id, normalized email, counts).
      per_company_rows = Employee.where(company_id: target_ids)
        .where(EmployeeContactValidator.present_node(Employee.arel_table[:email]))
        .group(:company_id, EmployeeContactValidator.normalized_email_node)
        .pluck(
          :company_id,
          EmployeeContactValidator.normalized_email_node,
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END)")
        )

      flagged_by_company = Hash.new { |hash, key| hash[key] = [] }
      distinct_flagged_emails = Set.new
      total_employee_records = 0
      active_employee_records = 0

      per_company_rows.each do |cid, email, total_count, active_count|
        total = total_count.to_i
        active = active_count.to_i
        inactive = total - active
        scoped_entry = accessible_stats[email] || { total_count: total, companies_count: 1 }

        # A demo company's rows never consult the organization's private
        # placeholder list, so they can't reveal which addresses are marked.
        private_hidden = DemoOutbound.demo_target?(company_by_id.fetch(cid), @actor)
        is_db_marked = !private_hidden && db_marked_placeholders.include?(email)
        is_configured = !private_hidden && configured_placeholders.include?(email)
        is_structural = EmployeeContactValidator.structural_placeholder_email?(email)
        # Only explicitly marked or configured addresses may be bulk-cleared.
        # Structural address patterns surface as candidates to review and mark.
        clearable = is_db_marked || is_configured

        reasons = reasons_for(
          company_count: total,
          scoped_entry: scoped_entry,
          is_db_marked: is_db_marked,
          is_configured: is_configured,
          is_structural: is_structural
        )
        next if reasons.empty?

        classification = clearable ? "placeholder" : "shared"
        distinct_flagged_emails.add(email)
        total_employee_records += total
        active_employee_records += active

        flagged_by_company[cid] << {
          email: email,
          total_count: total,
          active_count: active,
          inactive_count: inactive,
          companies_count: scoped_entry[:companies_count],
          organization_total_count: scoped_entry[:total_count],
          reasons: reasons,
          classification: classification,
          clearable: clearable,
          marked_placeholder: is_db_marked || is_configured,
          unmarkable: is_db_marked
        }
      end

      # The organization-wide list of marked addresses is authorized on its
      # own: never from a demo-scoped report, and only for an organization
      # administrator or staff who can configure a live client.
      listed_placeholders = placeholder_list_visible?(target_companies, configurable_companies) ? marked_placeholders : Set.new

      company_entries = flagged_by_company.map do |cid, emails|
        company = company_by_id.fetch(cid)
        sorted_emails = emails.sort_by { |item| [ item[:clearable] ? 0 : 1, -item[:total_count], item[:email] ] }
        {
          company_id: company.id,
          company_name: company.name,
          total_flagged_records: sorted_emails.sum { |item| item[:total_count] },
          active_flagged_records: sorted_emails.sum { |item| item[:active_count] },
          emails: sorted_emails
        }
      end.sort_by { |entry| [ -entry[:total_flagged_records], entry[:company_name].to_s.downcase ] }

      {
        summary: {
          companies_affected: company_entries.size,
          distinct_flagged_emails: distinct_flagged_emails.size,
          total_employee_records: total_employee_records,
          active_employee_records: active_employee_records
        },
        can_manage_placeholders: StaffRolePolicy.allowed?(@actor, :manage_organization),
        marked_placeholders: listed_placeholders.to_a.sort,
        # Listed even when no employee uses the address any more, so staff can
        # still unmark it. Configured addresses can't be unmarked here.
        placeholder_marks: listed_placeholders.to_a.sort.map do |email|
          { email: email, unmarkable: db_marked_placeholders.include?(email) && !configured_placeholders.include?(email) }
        end,
        companies: company_entries
      }
    end

    private

    def empty_report
      {
        summary: {
          companies_affected: 0,
          distinct_flagged_emails: 0,
          total_employee_records: 0,
          active_employee_records: 0
        },
        can_manage_placeholders: StaffRolePolicy.allowed?(@actor, :manage_organization),
        marked_placeholders: [],
        placeholder_marks: [],
        companies: []
      }
    end

    def placeholder_list_visible?(target_companies, configurable_companies)
      return false if target_companies.any?(&:demo?)

      StaffRolePolicy.allowed?(@actor, :manage_organization) || configurable_companies.any?(&:live_payroll?)
    end

    def all_configurable_companies
      scope = Company.where(active: true, test_workspace_archived_at: nil)
      scope = scope.where(organization_id: @organization_id) if @organization_id.present?
      scope = scope.where(payroll_environment: "live") unless @company_id.present?

      scope.order(:name).to_a.select do |company|
        @actor.can_access_company?(company.id) &&
          StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: company)
      end
    end

    def aggregate_accessible_email_stats(company_ids)
      return {} if company_ids.empty?

      Employee.where(company_id: company_ids)
        .where(EmployeeContactValidator.present_node(Employee.arel_table[:email]))
        .group(EmployeeContactValidator.normalized_email_node)
        .pluck(
          EmployeeContactValidator.normalized_email_node,
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(DISTINCT employees.company_id)")
        )
        .each_with_object({}) do |(email, total_count, companies_count), stats|
          stats[email] = {
            total_count: total_count.to_i,
            companies_count: companies_count.to_i
          }
        end
    end

    def reasons_for(company_count:, scoped_entry:, is_db_marked:, is_configured:, is_structural:)
      reasons = []
      reasons << "marked_placeholder" if is_db_marked
      reasons << "configured_placeholder" if is_configured
      reasons << "placeholder_pattern" if is_structural
      reasons << "shared_across_companies" if scoped_entry[:companies_count] >= 2
      reasons << "shared_within_company" if company_count >= 2
      reasons.uniq
    end
  end
end
