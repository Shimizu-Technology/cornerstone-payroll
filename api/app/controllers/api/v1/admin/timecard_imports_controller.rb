# frozen_string_literal: true

require "csv"

module Api
  module V1
    module Admin
      class TimecardImportsController < BaseController
        include TrigramMatching

        before_action :set_pay_period

        # POST /api/v1/admin/pay_periods/:pay_period_id/preview_timecard_import
        # Accepts CSV (file upload or raw text) from the Timecard OCR app export.
        # Returns parsed rows with fuzzy-matched employee mappings for review.
        def preview
          csv_data = extract_csv_data
          return render json: { error: "No CSV data provided" }, status: :unprocessable_entity unless csv_data

          rows = parse_csv(csv_data)
          return render json: { error: "CSV is empty or has no data rows" }, status: :unprocessable_entity if rows.empty?

          employees = Employee.active.where(company_id: current_company_id).to_a
          mapped = rows.map { |row| match_row_to_employee(row, employees) }

          render json: {
            preview: mapped,
            all_employees: employees.map { |e| { id: e.id, name: e.full_name } },
            total_rows: mapped.size,
            matched: mapped.count { |m| m[:employee_id].present? },
            unmatched: mapped.count { |m| m[:employee_id].nil? }
          }
        end

        # POST /api/v1/admin/pay_periods/:pay_period_id/apply_timecard_import
        # Applies confirmed timecard mappings to the pay period's payroll items.
        # Body: { mappings: [{ employee_id: 123, regular_hours: 80, overtime_hours: 4 }, ...] }
        def apply
          unless @pay_period.can_edit?
            return render json: { error: "Cannot apply to a non-draft pay period" }, status: :unprocessable_entity
          end

          mappings = Array(params[:mappings])
          return render json: { error: "No mappings provided" }, status: :unprocessable_entity if mappings.empty?

          results = { applied: [], skipped: [], errors: [] }

          ActiveRecord::Base.transaction do
            mappings.each do |mapping|
              eid = mapping[:employee_id].to_i
              next if eid.zero?

              employee = Employee.active.find_by(id: eid, company_id: current_company_id)
              unless employee
                results[:errors] << { employee_id: eid, error: "Employee not found or inactive" }
                next
              end

              item = @pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)
              if item.new_record?
                item.company_id = current_company_id
                item.employment_type = employee.employment_type
                item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
              end

              item.hours_worked = mapping[:regular_hours].to_f if mapping[:regular_hours].present?
              item.overtime_hours = mapping[:overtime_hours].to_f if mapping[:overtime_hours].present?
              item.import_source = "timecard_ocr"
              item.save!

              results[:applied] << {
                employee_id: employee.id,
                employee_name: employee.full_name,
                hours_worked: item.hours_worked,
                overtime_hours: item.overtime_hours
              }
            end
          end

          render json: results
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id])
          unless @pay_period.company_id == current_company_id
            render json: { error: "Pay period not found" }, status: :not_found
          end
        end

        def extract_csv_data
          if params[:file].present?
            params[:file].read
          elsif params[:csv_text].present?
            params[:csv_text]
          end
        end

        def parse_csv(raw)
          rows = []
          CSV.parse(raw, headers: true, liberal_parsing: true) do |csv_row|
            name = csv_row["Employee Name"].to_s.strip
            next if name.blank?

            rows << {
              employee_name: name,
              regular_hours: csv_row["Regular Hours"].to_s.strip,
              overtime_hours: csv_row["OT Hours"].to_s.strip,
              total_hours: csv_row["Total Hours"].to_s.strip,
              flags: csv_row["Flags"].to_s.strip
            }
          end
          rows
        end

        def match_row_to_employee(row, employees)
          name = row[:employee_name]
          best_match = nil
          best_score = 0

          employees.each do |emp|
            score = trigram_similarity(name, emp.full_name)
            if score > best_score
              best_score = score
              best_match = emp
            end

            # Also try last_name, first_name format
            reversed = "#{emp.last_name}, #{emp.first_name}"
            rev_score = trigram_similarity(name, reversed)
            if rev_score > best_score
              best_score = rev_score
              best_match = emp
            end
          end

          threshold = 0.6
          matched = best_score >= threshold

          {
            csv_name: name,
            regular_hours: row[:regular_hours],
            overtime_hours: row[:overtime_hours],
            total_hours: row[:total_hours],
            flags: row[:flags],
            employee_id: matched ? best_match&.id : nil,
            employee_name: matched ? best_match&.full_name : nil,
            match_score: best_score.round(2)
          }
        end

      end
    end
  end
end
