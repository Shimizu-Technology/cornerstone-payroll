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

          new_departments = result[:rows]
            .select { |r| r[:new_department] }
            .filter_map { |r| r[:raw]["department"]&.strip }
            .uniq

          render json: {
            rows: result[:rows].map { |r| serialize_preview_row(r) },
            summary: {
              total: result[:rows].size,
              valid: result[:rows].count { |r| r[:valid] },
              invalid: result[:rows].count { |r| !r[:valid] },
              duplicates: result[:rows].count { |r| r[:duplicate] },
              new_departments: new_departments
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

          create_result = service.create_employees!(valid_rows)

          render json: {
            created: create_result[:created],
            failed: create_result[:failed],
            errors: create_result[:errors]
          }
        end

        # POST /api/v1/admin/employee_bulk_imports/apply_json
        def apply_json
          employees_data = params[:employees]
          unless employees_data.is_a?(Array) && employees_data.any?
            return render json: { error: "No employee data provided" }, status: :unprocessable_entity
          end

          company = Company.find(current_company_id)
          service = EmployeeBulkImport::ImportService.new(company)

          rows = employees_data.each_with_index.map do |emp, idx|
            {
              row_number: idx + 1,
              attributes: sanitize_employee_attrs(emp),
              raw: emp.to_unsafe_h
            }
          end

          create_result = service.create_employees!(rows)

          render json: {
            created: create_result[:created],
            failed: create_result[:failed],
            errors: create_result[:errors]
          }
        end

        private

        PERMITTED_ATTRS = %i[
          first_name middle_name last_name email ssn_encrypted
          date_of_birth hire_date employment_type pay_rate pay_frequency
          filing_status allowances additional_withholding
          w4_dependent_credit w4_step2_multiple_jobs w4_step4a_other_income w4_step4b_deductions
          retirement_rate roth_retirement_rate
          department_id
          address_line1 address_line2 city state zip phone
          contractor_type contractor_pay_type business_name contractor_ein w9_on_file
          status
        ].freeze

        def sanitize_employee_attrs(emp_params)
          attrs = {}
          h = emp_params.respond_to?(:to_unsafe_h) ? emp_params.to_unsafe_h.symbolize_keys : emp_params.to_h.symbolize_keys

          PERMITTED_ATTRS.each do |key|
            attrs[key] = h[key] if h.key?(key)
          end

          # Handle SSN: if raw ssn provided (not ssn_encrypted), strip non-digits
          if h[:ssn].present? && !h.key?(:ssn_encrypted)
            attrs[:ssn_encrypted] = h[:ssn].to_s.gsub(/\D/, "")
          end

          # Handle department by name if _department_name provided
          if h[:_department_name].present?
            attrs[:_department_name] = h[:_department_name]
          end

          attrs[:status] ||= "active"
          attrs
        end

        def serialize_preview_row(row)
          raw = row[:raw]
          {
            row_number: row[:row_number],
            data: {
              first_name: raw["first_name"],
              last_name: raw["last_name"],
              middle_name: raw["middle_name"],
              email: raw["email"],
              ssn: raw["ssn"].present? ? "***-**-#{raw['ssn'].gsub(/\D/, '').last(4)}" : nil,
              date_of_birth: raw["date_of_birth"],
              hire_date: raw["hire_date"],
              employment_type: raw["employment_type"],
              pay_rate: raw["pay_rate"],
              pay_frequency: raw["pay_frequency"],
              filing_status: raw["filing_status"],
              allowances: raw["allowances"],
              additional_withholding: raw["additional_withholding"],
              w4_dependent_credit: raw["w4_dependent_credit"],
              w4_step2_multiple_jobs: raw["w4_step2_multiple_jobs"],
              w4_step4a_other_income: raw["w4_step4a_other_income"],
              w4_step4b_deductions: raw["w4_step4b_deductions"],
              retirement_rate: raw["retirement_rate"],
              roth_retirement_rate: raw["roth_retirement_rate"],
              department: raw["department"],
              address_line1: raw["address_line1"],
              address_line2: raw["address_line2"],
              city: raw["city"],
              state: raw["state"],
              zip: raw["zip"],
              phone: raw["phone"],
              contractor_type: raw["contractor_type"],
              contractor_pay_type: raw["contractor_pay_type"],
              business_name: raw["business_name"],
              contractor_ein: raw["contractor_ein"],
              w9_on_file: raw["w9_on_file"]
            },
            valid: row[:valid],
            duplicate: row[:duplicate],
            new_department: row[:new_department] || false,
            errors: row[:errors]
          }
        end
      end
    end
  end
end
