# frozen_string_literal: true

module EmployeeContactHygiene
  class SharedEmailReport
    def initialize(actor:, organization_id:, company_id: nil)
      @actor = actor
      @organization_id = organization_id
      @company_id = company_id
    end

    def call
      companies = accessible_companies
      return empty_report if companies.empty?

      company_ids = companies.map(&:id)
      company_by_id = companies.index_by(&:id)
      org_id = @organization_id || companies.first.organization_id

      configured_placeholders = EmployeeContactValidator.configured_placeholder_emails
      org_shared_inboxes = EmployeeContactValidator.data_detected_shared_inbox_emails(organization_id: org_id)

      # Aggregate counts across the organization for context (no PII).
      org_stats = aggregate_org_email_stats(org_id)

      # Per-company aggregate counts (no PII — only company_id, normalized email, counts).
      per_company_rows = Employee.where(company_id: company_ids)
        .where("COALESCE(TRIM(email), '') <> ''")
        .group(:company_id, Arel.sql("LOWER(TRIM(email))"))
        .pluck(
          :company_id,
          Arel.sql("LOWER(TRIM(email))"),
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
        org_entry = org_stats[email] || { total_count: total, companies_count: 1 }

        reasons = reasons_for(
          email: email,
          company_count: total,
          org_entry: org_entry,
          configured_placeholders: configured_placeholders,
          org_shared_inboxes: org_shared_inboxes
        )
        next if reasons.empty?

        classification = classify(reasons)
        distinct_flagged_emails.add(email)
        total_employee_records += total
        active_employee_records += active

        flagged_by_company[cid] << {
          email: email,
          total_count: total,
          active_count: active,
          inactive_count: inactive,
          companies_count: org_entry[:companies_count],
          organization_total_count: org_entry[:total_count],
          reasons: reasons,
          classification: classification
        }
      end

      company_entries = flagged_by_company.map do |cid, emails|
        company = company_by_id.fetch(cid)
        sorted_emails = emails.sort_by { |item| [ -item[:total_count], item[:email] ] }
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
        companies: []
      }
    end

    def accessible_companies
      scope = Company.where(active: true, test_workspace_archived_at: nil)
      scope = scope.where(organization_id: @organization_id) if @organization_id.present?
      if @company_id.present?
        scope = scope.where(id: @company_id)
      else
        scope = scope.where(payroll_environment: "live")
      end

      scope.order(:name).to_a.select do |company|
        @actor.can_access_company?(company.id) &&
          StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: company)
      end
    end

    def aggregate_org_email_stats(organization_id)
      return {} if organization_id.blank?

      Employee.joins(:company)
        .where(companies: { organization_id: organization_id, payroll_environment: "live" })
        .where("COALESCE(TRIM(employees.email), '') <> ''")
        .group(Arel.sql("LOWER(TRIM(employees.email))"))
        .pluck(
          Arel.sql("LOWER(TRIM(employees.email))"),
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

    def reasons_for(email:, company_count:, org_entry:, configured_placeholders:, org_shared_inboxes:)
      reasons = []
      reasons << "configured_placeholder" if configured_placeholders.include?(email)
      reasons << "placeholder_pattern" if EmployeeContactValidator.structural_placeholder_email?(email)
      reasons << "shared_across_companies" if org_entry[:companies_count] >= 2 && org_shared_inboxes.include?(email)
      reasons << "shared_inbox" if org_shared_inboxes.include?(email)
      reasons << "shared_within_company" if company_count >= 2
      reasons.uniq
    end

    def classify(reasons)
      return "placeholder" if reasons.include?("configured_placeholder") || reasons.include?("placeholder_pattern")
      return "shared_inbox" if reasons.include?("shared_inbox")

      "shared"
    end
  end
end
