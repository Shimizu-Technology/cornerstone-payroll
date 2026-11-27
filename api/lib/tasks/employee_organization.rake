# frozen_string_literal: true

namespace :employee_organization do
  desc "Count wage-rate department assignments; set APPLY=true to save"
  task map_departments: :environment do
    company_id = Integer(ENV.fetch("COMPANY_ID", ""), 10, exception: false)
    abort "COMPANY_ID is required." unless company_id&.positive?

    entries = ENV.fetch("LABEL_MAP", "").split(",", -1).map { |entry| entry.split("=", -1).map(&:strip) }
    if entries.empty? || entries.any? { |entry| entry.size != 2 || entry.any?(&:blank?) } ||
        entries.map(&:first).uniq.size != entries.size
      abort "LABEL_MAP must contain unique label=department pairs."
    end

    begin
      TenantScope.with_company(company_id) do
        apply = ENV["APPLY"] == "true"
        counts = WageRateDepartmentAssignment.new(company: Company.find(company_id), label_map: entries.to_h).call(apply: apply)
        puts counts.merge(applied: apply ? 1 : 0).to_json
      end
    rescue ActiveRecord::ActiveRecordError
      abort "Department assignment failed. No changes were saved."
    end
  end
end
