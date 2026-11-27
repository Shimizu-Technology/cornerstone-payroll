# frozen_string_literal: true

# The employee app status report (EmployeeAppStatusReport) for one company:
# JSON for the page, and the same rows as CSV or XLSX. Read-only, so client
# viewers can use it; the company comes from the explicit company context.
module EmployeeAppStatusActions
  extend ActiveSupport::Concern

  included do
    before_action :disable_response_caching
    before_action :check_report_company
  end

  def show
    render json: { data: report_data }
  end

  def csv
    report = EmployeeAppStatusReport.new(current_company)
    exporter = TabularReportCsvExporter.new(filename: report.filename(:csv), sheet: report.sheet(report.export_rows(**report_params)))
    send_data exporter.generate, filename: exporter.filename, type: "text/csv; charset=utf-8", disposition: "attachment"
  end

  def xlsx
    report = EmployeeAppStatusReport.new(current_company)
    exporter = SpreadsheetReportExporter.new(filename: report.filename(:xlsx), sheets: [ report.sheet(report.export_rows(**report_params)) ])
    send_data exporter.generate, filename: exporter.filename, type: SpreadsheetReportExporter::CONTENT_TYPE, disposition: "attachment"
  end

  private

  def disable_response_caching
    response.headers["Cache-Control"] = "private, no-store"
  end

  def check_report_company
    return if current_company && params[:company_id] == current_company.id.to_s

    render json: { error: "Company not found." }, status: :not_found
  end

  def report_data
    EmployeeAppStatusReport.new(current_company).call(**report_params)
  end

  # The page and both exports read the same params, so an export matches the
  # result it was asked for.
  def report_params
    { filter: string_param(:filter), department_id: string_param(:department_id), role: string_param(:role), query: string_param(:q) }
  end

  def string_param(key)
    value = params[key]
    value.is_a?(String) ? value.first(200) : nil
  end
end
