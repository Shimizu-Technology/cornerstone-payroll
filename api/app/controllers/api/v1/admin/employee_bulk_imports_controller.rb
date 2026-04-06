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

          preview_id = SecureRandom.uuid
          ssn_cache = {}

          rows_json = result[:rows].map do |r|
            row_data = serialize_preview_row(r)
            raw_ssn = r[:raw]["ssn"]
            if raw_ssn.present?
              digits = raw_ssn.gsub(/\D/, "")
              if digits.length == 9
                token = SecureRandom.hex(16)
                ssn_cache[token] = digits
                row_data[:data][:_ssn_token] = token
              end
            end
            row_data
          end

          if ssn_cache.any?
            Rails.cache.write(
              "bulk_import_ssn:#{preview_id}",
              ssn_cache,
              expires_in: 30.minutes
            )
          end

          render json: {
            preview_id: preview_id,
            rows: rows_json,
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

          ssn_cache = nil
          if params[:preview_id].present?
            ssn_cache = Rails.cache.read("bulk_import_ssn:#{params[:preview_id]}")
          end

          company = Company.find(current_company_id)
          service = EmployeeBulkImport::ImportService.new(company)

          rows = employees_data.each_with_index.map do |emp, idx|
            {
              row_number: idx + 1,
              attributes: sanitize_employee_attrs(emp, ssn_cache),
              raw: emp.to_unsafe_h
            }
          end

          create_result = service.create_employees!(rows)

          # Clean up the SSN cache after use
          if params[:preview_id].present?
            Rails.cache.delete("bulk_import_ssn:#{params[:preview_id]}")
          end

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

        def sanitize_employee_attrs(emp_params, ssn_cache = nil)
          attrs = {}
          h = emp_params.respond_to?(:to_unsafe_h) ? emp_params.to_unsafe_h.symbolize_keys : emp_params.to_h.symbolize_keys

          PERMITTED_ATTRS.each do |key|
            attrs[key] = h[key] if h.key?(key)
          end

          # SSN resolution order:
          # 1. _ssn_token -> look up raw digits from server-side cache (file-originated, not edited)
          # 2. ssn -> user-provided raw digits (manually added or user-edited SSN field)
          if h[:_ssn_token].present? && ssn_cache
            digits = ssn_cache[h[:_ssn_token].to_s]
            attrs[:ssn_encrypted] = digits if digits.present? && digits.length == 9
          elsif h[:ssn].present? && !h.key?(:ssn_encrypted)
            digits = h[:ssn].to_s.gsub(/\D/, "")
            attrs[:ssn_encrypted] = digits if digits.length == 9
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
