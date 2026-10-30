# frozen_string_literal: true

namespace :payroll do
  namespace :fica_legacy do
    desc "Read-only inventory of legacy FICA evidence by company and employee-year"
    task inventory: :environment do
      puts JSON.pretty_generate(FicaLegacyTaskInventory.call)
    end

    desc "Preview source-completeness reviews (default); APPLY=1 records the entire reviewed batch"
    task review_sources: :environment do
      raise ArgumentError, "Use EMPLOYEE_ID or EMPLOYEE_IDS, not both" if ENV["EMPLOYEE_ID"].present? && ENV["EMPLOYEE_IDS"].present?
      raise ArgumentError, "APPLY must be 1" if ENV["APPLY"].present? && ENV["APPLY"] != "1"
      raise ArgumentError, "DRY_RUN must be 1" if ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "1"
      raise ArgumentError, "APPLY=1 and DRY_RUN=1 conflict" if ENV["APPLY"] == "1" && ENV["DRY_RUN"] == "1"
      ids = ENV.fetch("EMPLOYEE_IDS") { ENV.fetch("EMPLOYEE_ID") }.split(",", -1).map { |id| Integer(id.strip) }
      company_id = Integer(ENV.fetch("COMPANY_ID"))
      year = Integer(ENV.fetch("TAX_YEAR"))
      apply = ENV["APPLY"] == "1"
      EmployeeYearFicaSourceReview.transaction do
        Company.lock.find(company_id)
        reviews = EmployeeYearFicaSourceReview.record_batch!(company_id: company_id, employee_ids: ids,
          actor: User.find(Integer(ENV.fetch("ACTOR_ID"))), apply: apply,
          tax_year: year, through_pay_date: Date.iso8601(ENV.fetch("THROUGH_PAY_DATE")),
          external_ss_wage_bound: FicaBasisEvidence.amount(ENV.fetch("EXTERNAL_SS_WAGE_BOUND")),
          external_medicare_wage_bound: FicaBasisEvidence.amount(ENV.fetch("EXTERNAL_MEDICARE_WAGE_BOUND")),
          review_reference: ENV.fetch("REVIEW_REFERENCE"))
        inventory = PayrollFicaLegacyRecovery.new(company: Company.find(company_id), year: year).inventory
        puts JSON.pretty_generate(mode: apply ? "apply" : "dry-run", reviews: reviews.map do |review|
          { employee_id: review.employee_id, employee_name: review.employee.full_name, review: review.attributes,
            inventory: inventory[:employee_years].find { |entry| entry[:employee_id] == review.employee_id } ||
              { employee_id: review.employee_id, tax_year: year, status: "no_committed_history" } }
        end)
      end
    end

    desc "Review legacy FICA recovery (dry-run by default); use bin/rake ... --apply with a reviewed plan"
    task :recover, [ :mode ] => :environment do |_task, args|
      mode = args[:mode] || "dry-run"
      raise ArgumentError, "Recovery mode must be dry-run or apply" unless %w[dry-run apply].include?(mode)
      if mode == "apply"
        company = Company.find(Integer(ENV.fetch("COMPANY_ID")))
        service = PayrollFicaLegacyRecovery.new(company: company, year: Integer(ENV.fetch("TAX_YEAR")))
        result = service.apply!(actor: User.find(Integer(ENV.fetch("ACTOR_ID"))),
          review_reference: ENV.fetch("REVIEW_REFERENCE"), expected_digest: ENV.fetch("PLAN_DIGEST"))
        puts JSON.pretty_generate(mode: mode, result: result)
      else
        puts JSON.pretty_generate(FicaLegacyTaskInventory.call.merge(mode: "dry-run"))
      end
    end
  end
end

module FicaLegacyTaskInventory
  def self.call
    connection = ApplicationRecord.connection
    return inventory if connection.transaction_open?

    connection.transaction(isolation: :repeatable_read) do
      connection.execute("SET TRANSACTION READ ONLY")
      inventory
    end
  end

  def self.inventory
    companies = ENV["COMPANY_ID"].present? ? Company.where(id: Company.find(Integer(ENV.fetch("COMPANY_ID"))).id) : Company.all
    results = []
    companies.find_each do |company|
      years = if ENV["TAX_YEAR"].present?
        [ Integer(ENV.fetch("TAX_YEAR")) ]
      else
        PayPeriod.where(company_id: company.id, status: "committed").distinct
          .pluck(Arel.sql("EXTRACT(YEAR FROM pay_date)::integer")).sort
      end
      years.each { |year| results << PayrollFicaLegacyRecovery.new(company: company, year: year).inventory }
    end
    { mode: "inventory", company_years: results }
  end
end
