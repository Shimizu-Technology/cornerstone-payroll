# frozen_string_literal: true

require "csv"
require "json"
require "zip"

class PayrollRegisterHistoryPackageExporter
  CONTENT_TYPE = "application/zip"
  FORMATS = %w[xlsx pdf].freeze
  MANIFEST_HEADERS = [
    "Pay run key", "Source", "Status", "Work period start", "Work period end", "Pay date",
    "W-2 employees", "1099 contractors", "W-2 gross", "1099 gross", "Combined gross",
    "W-2 net", "1099 net", "Combined net", "Report file"
  ].freeze

  attr_reader :filename

  def initialize(company:, format:, entries:)
    @company = company
    @format = format.to_s
    @entries = Array(entries)
    raise ArgumentError, "format must be xlsx or pdf" unless @format.in?(FORMATS)
    raise ArgumentError, "No reportable payroll runs were found" if @entries.empty?

    company_slug = company.name.to_s.parameterize.presence || "company"
    @filename = "payroll_history_#{company_slug}_#{Date.current}.zip"
  end

  def generate
    buffer = Zip::OutputStream.write_buffer do |archive|
      write_entry(archive, "README.txt", readme)
      write_entry(archive, "manifest.csv", manifest_csv)
      write_entry(archive, "manifest.json", JSON.pretty_generate(manifest_payload))
      entries.each { |entry| write_entry(archive, entry.fetch(:path), entry.fetch(:content)) }
    end
    buffer.rewind
    buffer.read
  end

  private

  attr_reader :company, :format, :entries

  def write_entry(archive, path, content)
    archive.put_next_entry(path)
    archive.write(content)
  end

  def manifest_csv
    CSV.generate do |csv|
      csv << MANIFEST_HEADERS
      entries.each { |entry| csv << manifest_row(entry) }
    end
  end

  def manifest_payload
    {
      company: company.name,
      generated_at: Time.current.iso8601,
      report_format: format,
      payroll_run_count: entries.length,
      payroll_runs: entries.map { |entry| manifest_hash(entry) }
    }
  end

  def manifest_row(entry)
    row = manifest_hash(entry)
    [
      row[:pay_run_key], row[:source], row[:status], row[:work_period_start], row[:work_period_end], row[:pay_date],
      row[:w2_employee_count], row[:contractor_count], row[:w2_gross], row[:contractor_gross], row[:combined_gross],
      row[:w2_net], row[:contractor_net], row[:combined_net], row[:report_file]
    ]
  end

  def manifest_hash(entry)
    report = entry.fetch(:report)
    period = report.fetch(:pay_period)
    summary = report.fetch(:summary, {})
    contractor_gross = summary[:contractor_total_gross].to_d
    contractor_net = summary[:contractor_total_net].to_d
    w2_gross = summary[:total_gross].to_d
    w2_net = summary[:total_net].to_d

    {
      pay_run_key: period[:key] || "#{period[:record_type] || 'native'}:#{period[:id]}",
      source: report.dig(:source, :label),
      status: period[:status],
      work_period_start: period[:start_date],
      work_period_end: period[:end_date],
      pay_date: period[:pay_date],
      w2_employee_count: summary[:employee_count].to_i,
      contractor_count: summary[:contractor_count].to_i,
      w2_gross: w2_gross.to_f,
      contractor_gross: contractor_gross.to_f,
      combined_gross: (w2_gross + contractor_gross).to_f,
      w2_net: w2_net.to_f,
      contractor_net: contractor_net.to_f,
      combined_net: (w2_net + contractor_net).to_f,
      report_file: entry.fetch(:path)
    }
  end

  def readme
    <<~TEXT
      Complete payroll history for #{company.name}

      This package contains one #{format.upcase} payroll register for every reportable payroll run,
      plus CSV and JSON manifests for reconciliation. W-2 employees and 1099 contractors are kept
      in separate report sections. The manifest reports each group separately and also provides
      combined gross and net totals.

      Date meanings:
      - Work period start/end: when the work was performed.
      - Pay date: when the payroll was paid. Tax and cumulative payroll reports use pay date.

      Generated: #{Time.current.iso8601}
    TEXT
  end
end
