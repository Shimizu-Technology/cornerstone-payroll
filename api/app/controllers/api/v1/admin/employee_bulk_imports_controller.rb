# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeBulkImportsController < BaseController
        # GET /api/v1/admin/employee_bulk_imports/template
        def template
          csv_data = EmployeeBulkImport::ImportService.template_csv
          send_data csv_data,
            filename: "employee_import_template.csv",
            type: "text/csv; charset=utf-8",
            disposition: "attachment"
        end

        # POST /api/v1/admin/employee_bulk_imports/preview
        def preview
          file = params[:file]
          unless file
            return render json: { error: "No file uploaded" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          service = EmployeeBulkImport::ImportService.new(company)
          result = service.parse(file)

          if result[:errors].any?
            return render json: { error: result[:errors].join("; ") }, status: :unprocessable_entity
          end

          render json: {
            rows: result[:rows].map { |r| serialize_preview_row(r) },
            summary: {
              total: result[:rows].size,
              valid: result[:rows].count { |r| r[:valid] },
              invalid: result[:rows].count { |r| !r[:valid] },
              duplicates: result[:rows].count { |r| r[:duplicate] }
            }
          }
        end

        # POST /api/v1/admin/employee_bulk_imports/apply
        def apply
          file = params[:file]
          skip_rows = Array(params[:skip_rows]).map(&:to_i).to_set

          unless file
            return render json: { error: "No file uploaded" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          service = EmployeeBulkImport::ImportService.new(company)
          result = service.parse(file)

          if result[:errors].any?
            return render json: { error: result[:errors].join("; ") }, status: :unprocessable_entity
          end

          valid_rows = result[:rows].select { |r| r[:valid] && !skip_rows.include?(r[:row_number]) }

          if valid_rows.empty?
            return render json: { error: "No valid rows to import" }, status: :unprocessable_entity
          end

          create_result = service.create_employees!(valid_rows, created_by: current_user)

          render json: {
            created: create_result[:created],
            failed: create_result[:failed],
            errors: create_result[:errors]
          }
        end

        private

        def serialize_preview_row(row)
          {
            row_number: row[:row_number],
            data: {
              first_name: row[:raw]["first_name"],
              last_name: row[:raw]["last_name"],
              middle_name: row[:raw]["middle_name"],
              email: row[:raw]["email"],
              ssn: row[:raw]["ssn"].present? ? "***-**-#{row[:raw]['ssn'].gsub(/\D/, '').last(4)}" : nil,
              date_of_birth: row[:raw]["date_of_birth"],
              hire_date: row[:raw]["hire_date"],
              employment_type: row[:raw]["employment_type"],
              pay_rate: row[:raw]["pay_rate"],
              pay_frequency: row[:raw]["pay_frequency"],
              filing_status: row[:raw]["filing_status"],
              department: row[:raw]["department"],
              address_line1: row[:raw]["address_line1"],
              city: row[:raw]["city"],
              state: row[:raw]["state"],
              zip: row[:raw]["zip"],
              phone: row[:raw]["phone"]
            },
            valid: row[:valid],
            duplicate: row[:duplicate],
            errors: row[:errors]
          }
        end
      end
    end
  end
end
