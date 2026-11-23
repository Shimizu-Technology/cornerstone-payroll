# frozen_string_literal: true

require_relative "../rls_task"

require "csv"

namespace :year_end do
  desc "Read-only per-company old/new W-2GU wage totals (YEAR=2026; optional COMPANY_ID)"
  RlsTask.system wage_impact: :environment do
    year = Integer(ENV.fetch("YEAR", "2026"))
    # Database-enforced read-only transaction: no repair, backfill, seed or save.
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      companies = ENV["COMPANY_ID"] ? Company.where(id: Integer(ENV.fetch("COMPANY_ID"))) : Company.all
      puts CSV.generate_line(%w[company_id year old_box1 new_box1 delta_box1 old_box3 new_box3 delta_box3 old_box5 new_box5 delta_box5])
      companies.order(:id).find_each do |company|
        impact = W2GuWageImpact.new(company, year).generate
        puts CSV.generate_line([ company.id, year, *impact.values_at(:box1, :box3, :box5).flatten.map { |amount| format("%.2f", amount) } ])
      rescue StandardError => e
        # One company's problem must not hide every other company's result.
        warn "company #{company.id}: #{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
      end
    end
  end
end
