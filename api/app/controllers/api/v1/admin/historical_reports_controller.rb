# frozen_string_literal: true

module Api
  module V1
    module Admin
      class HistoricalReportsController < BaseController
        DEFAULT_PER_PAGE = 50
        MAX_PER_PAGE = 200

        before_action :require_historical_payroll_enabled!

        def show
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          report = report_builder.call(page: page, per_page: per_page)
          total_count = report.dig(:summary, :row_count)

          render json: {
            data: report,
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total_count,
              total_pages: (total_count.to_f / per_page).ceil
            }
          }
        rescue ArgumentError => e
          render json: { error: e.message, details: {} }, status: :unprocessable_entity
        end

        def csv
          export!(:csv)
        end

        def xlsx
          export!(:xlsx)
        end

        def pdf
          export!(:pdf)
        end

        private

        def require_historical_payroll_enabled!
          return if current_company&.historical_payroll_enabled?

          render json: { error: "Historical payroll is not enabled for this client", details: {} }, status: :forbidden
        end

        def report_builder
          QuickbooksHistory::ReportBuilder.new(
            company: current_company,
            report_type: params[:report_type],
            year: params[:year],
            worker_key: params[:worker_key]
          )
        end

        def export!(format)
          builder = report_builder
          report = builder.call
          enforce_export_limit!(report, format)
          sheets = builder.sheets(report)

          bytes, content_type = export_bytes(format, report, sheets, builder)
          record_export_audit!(report, format)
          send_data bytes,
                    filename: builder.filename(format),
                    type: content_type,
                    disposition: "attachment"
        rescue ArgumentError => e
          render json: { error: e.message, details: {} }, status: :unprocessable_entity
        end

        def enforce_export_limit!(report, format)
          count = report.fetch(:rows).size
          limit = format == :pdf ? QuickbooksHistory::ReportBuilder::MAX_PDF_ROWS : QuickbooksHistory::ReportBuilder::MAX_EXPORT_ROWS
          return if count <= limit

          raise ArgumentError, "This report has #{count} rows. Select a year or worker before exporting #{format.to_s.upcase}."
        end

        def export_bytes(format, report, sheets, builder)
          case format
          when :csv
            exporter = TabularReportCsvExporter.new(filename: builder.filename(:csv), sheet: sheets.fetch(1))
            [ exporter.generate, "text/csv; charset=utf-8" ]
          when :xlsx
            exporter = SpreadsheetReportExporter.new(filename: builder.filename(:xlsx), sheets: sheets)
            [ exporter.generate, SpreadsheetReportExporter::CONTENT_TYPE ]
          when :pdf
            generator = TabularReportPdfGenerator.new(
              title: report.fetch(:title),
              subtitle: "#{current_company.name} — #{report.fetch(:source_statement)}",
              filename: builder.filename(:pdf),
              sheets: sheets
            )
            [ generator.generate, "application/pdf" ]
          end
        end

        def record_export_audit!(report, format)
          AuditLog.record!(
            user: current_user,
            organization_id: current_company.organization_id,
            company_id: current_company.id,
            action: "historical_reports#export",
            record_type: "historical_payroll_reports",
            subject_name: report.fetch(:title),
            metadata: {
              report_type: report.fetch(:report_type),
              format: format,
              year: report.dig(:filters, :year),
              worker_filtered: report.dig(:filters, :worker_key).present?,
              row_count: report.fetch(:rows).size,
              source_batch_ids: report.fetch(:provenance).pluck(:batch_id)
            }
          )
        end
      end
    end
  end
end
