# frozen_string_literal: true

namespace :payroll do
  namespace :fica_legacy do
    desc "Read-only inventory of legacy FICA evidence by company and employee-year"
    task inventory: :environment do
      puts JSON.pretty_generate(FicaLegacyTaskInventory.call)
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
