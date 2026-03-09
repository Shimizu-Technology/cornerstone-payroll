#!/usr/bin/env ruby
# frozen_string_literal: true

# Backfill missing MoSa employees based on unmatched Revel PDF names across 2025 periods.
# Dry-run:   rails runner scripts/mosa_backfill_employees.rb
# Apply:     APPLY=1 rails runner scripts/mosa_backfill_employees.rb

require "set"

COMPANY_NAME = "MoSa's Joint"
DATA_DIR = File.expand_path("../../data/mosa-2025/raw", __dir__)
APPLY = ENV["APPLY"] == "1"

if Rails.env.production?
  puts "ERROR: This script cannot be run in production (creates skeleton employee records)."
  exit 1
end

PAYROLL_PDFS = Dir.glob(File.join(DATA_DIR, "payroll_*.pdf")).sort

company = Company.find_by(name: COMPANY_NAME)
raise "Company not found: #{COMPANY_NAME}" unless company

employees = Employee.where(company_id: company.id)
matcher = PayrollImport::NameMatcher.new(employees.active)

unmatched = Set.new

PAYROLL_PDFS.each do |pdf|
  PayrollImport::RevelPdfParser.parse(pdf).each do |row|
    unmatched << row[:employee_name] unless matcher.match_pdf_name(row[:employee_name])
  end
end

# Normalize to deterministic records
records = unmatched.map do |full_name|
  last, first = full_name.split(",", 2).map { |s| s.to_s.strip }
  next if last.blank? || first.blank?

  # Keep full first segment (supports names like "Young Paul")
  {
    source_name: full_name,
    last_name: last,
    first_name: first.gsub(/\s+/, " ").strip
  }
end.compact

# Deduplicate by last+first pair
records.uniq! { |r| "#{r[:last_name].downcase}|#{r[:first_name].downcase}" }

existing_keys = employees.map { |e| "#{e.last_name.downcase}|#{e.first_name.downcase}" }.to_set
missing = records.reject { |r| existing_keys.include?("#{r[:last_name].downcase}|#{r[:first_name].downcase}") }

puts "MoSa employee backfill"
puts "Company: #{company.name} (id=#{company.id})"
puts "PDF files scanned: #{PAYROLL_PDFS.count}"
puts "Unique unmatched names: #{unmatched.count}"
puts "Candidate unique employees: #{records.count}"
puts "Missing employee records: #{missing.count}"

missing.first(30).each do |r|
  puts "  - #{r[:last_name]}, #{r[:first_name]}"
end
puts "  ..." if missing.count > 30

unless APPLY
  puts "\nDry-run only. Re-run with APPLY=1 to create records."
  exit 0
end

created = 0
errors = []

Employee.transaction do
  missing.each do |r|
    begin
      Employee.create!(
        company_id: company.id,
        first_name: r[:first_name],
        last_name: r[:last_name],
        pay_rate: 0,
        employment_type: "hourly",
        pay_frequency: "biweekly",
        status: "active",
        filing_status: "single",
        allowances: 0
      )
      created += 1
    rescue => e
      errors << "#{r[:source_name]} => #{e.message}"
    end
  end
end

puts "\nCreated employees: #{created}"
puts "Errors: #{errors.count}"
errors.first(20).each { |e| puts "  - #{e}" }
