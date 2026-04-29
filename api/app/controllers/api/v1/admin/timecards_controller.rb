# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimecardsController < BaseController
        include TrigramMatching

        before_action :set_timecard, only: [:show, :update, :review, :reprocess, :destroy]

        # GET /api/v1/admin/timecards?pay_period_id=123&status=complete&page=1&per_page=20&search=smith
        def index
          timecards = Timecard.includes(:punch_entries).where(company_id: current_company_id)
          timecards = timecards.where(pay_period_id: params[:pay_period_id]) if params[:pay_period_id].present?
          timecards = timecards.where(ocr_status: params[:status]) if params[:status].present?

          if params[:search].present?
            term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip)}%"
            timecards = timecards.left_joins(:pay_period).where(
              <<~SQL.squish,
                timecards.employee_name ILIKE :term
                OR timecards.period_start::text ILIKE :term
                OR timecards.period_end::text ILIKE :term
                OR pay_periods.start_date::text ILIKE :term
                OR pay_periods.end_date::text ILIKE :term
                OR pay_periods.pay_date::text ILIKE :term
              SQL
              term: term
            )
          end

          total_count = timecards.count

          if params[:page].present?
            page = [params[:page].to_i, 1].max
            per_page = [params[:per_page].to_i, 1].max.clamp(1, 100)
            offset = (page - 1) * per_page

            ordered = timecards.order(created_at: :desc).offset(offset).limit(per_page)
            render json: {
              timecards: ordered.map { |tc| timecard_json(tc) },
              meta: { page: page, per_page: per_page, total_count: total_count, total_pages: (total_count.to_f / per_page).ceil }
            }
          else
            prioritized = timecards.to_a.sort_by do |tc|
              summary = TimecardOcr::ReviewSummary.build(tc)
              [summary["priority_rank"], -tc.created_at.to_i]
            end

            render json: prioritized.map { |tc| timecard_json(tc) }
          end
        end

        # GET /api/v1/admin/timecards/:id
        def show
          render json: timecard_json(@timecard)
        end

        # POST /api/v1/admin/timecards
        def create
          file = params[:image]
          return render json: { error: "No image provided" }, status: :unprocessable_entity unless file

          pay_period_id = params[:pay_period_id].presence

          segments = TimecardOcr::CardSegmentationService.segment(file.tempfile.path)

          timecards = segments.map do |segment|
            image_hash = Digest::SHA256.hexdigest(File.read(segment.path))
            existing = Timecard.find_by(company_id: current_company_id, image_hash: image_hash)
            if existing
              if existing.failed?
                existing.update!(ocr_status: :pending)
                enqueue_ocr(existing.id)
              end
              next existing
            end

            key = "#{current_company_id}/#{SecureRandom.uuid}/original.jpg"
            image_reference = TimecardOcr::StorageService.upload(segment.path, key, content_type: "image/jpeg")

            timecard = Timecard.create!(
              company_id: current_company_id,
              pay_period_id: pay_period_id,
              image_url: image_reference,
              image_hash: image_hash,
              ocr_status: :pending
            )
            enqueue_ocr(timecard.id)
            timecard
          end

          render json: timecards.map { |tc| timecard_json(tc) }
        ensure
          segments&.each do |segment|
            segment&.close
            segment&.unlink
          end
        end

        # PATCH /api/v1/admin/timecards/:id
        def update
          attrs = timecard_params.to_h

          if @timecard.reviewed? && header_changed?(@timecard, attrs)
            attrs.merge!(
              ocr_status: :complete,
              reviewed_by_name: nil,
              reviewed_at: nil
            )
          end

          @timecard.update!(attrs)
          render json: timecard_json(@timecard)
        end

        # PATCH /api/v1/admin/timecards/:id/review
        def review
          unless @timecard.reviewable?
            return render json: { error: "Timecard is not ready for review" }, status: :unprocessable_entity
          end

          reviewer_name = review_params[:reviewed_by_name].to_s.strip.presence

          summary = TimecardOcr::ReviewSummary.build(@timecard)
          if summary["attention_count"].positive?
            return render json: { error: "Resolve or approve all flagged rows before marking reviewed" }, status: :unprocessable_entity
          end

          @timecard.update!(ocr_status: :reviewed, reviewed_by_name: reviewer_name, reviewed_at: Time.current)
          render json: timecard_json(@timecard)
        end

        # PATCH /api/v1/admin/timecards/:id/reprocess
        def reprocess
          unless @timecard.reprocessable?
            return render json: { error: "Timecard cannot be reprocessed right now" }, status: :unprocessable_entity
          end

          @timecard.update!(ocr_status: :pending)
          enqueue_ocr(@timecard.id)
          render json: timecard_json(@timecard.reload)
        end

        # DELETE /api/v1/admin/timecards/:id
        def destroy
          @timecard.destroy!
          head :no_content
        end

        # POST /api/v1/admin/timecards/:id/apply_to_payroll
        def apply_to_payroll
          timecard = Timecard.find_by!(id: params[:id], company_id: current_company_id)
          pay_period = PayPeriod.find_by!(id: params[:pay_period_id], company_id: current_company_id)

          unless timecard.reviewed?
            return render json: { error: "Timecard must be reviewed before applying to payroll" }, status: :unprocessable_entity
          end

          unless pay_period.can_edit?
            return render json: { error: "Cannot apply to a non-draft pay period" }, status: :unprocessable_entity
          end

          employee = find_or_match_employee(timecard)
          unless employee
            return render json: { error: "Could not match timecard employee. Please specify employee_id." }, status: :unprocessable_entity
          end

          total_hours = timecard.punch_entries.where.not(hours_worked: nil).sum(:hours_worked)
          item = nil
          multi_rate_error = nil

          begin
            ApplicationRecord.transaction do
              item = pay_period.payroll_items.lock.find_or_initialize_by(employee_id: employee.id)
              if item.new_record?
                item.company_id = current_company_id
                item.employment_type = employee.employment_type
                item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
              end

              multi_rate_error = apply_timecard_hours_to_payroll_item(item, employee, total_hours)
              raise ActiveRecord::Rollback if multi_rate_error

              item.import_source = "timecard_ocr"
              item.custom_earnings = employee.default_custom_earnings if item.new_record? && item.custom_earnings.blank?
              item.calculate!

              timecard.update!(
                pay_period: pay_period,
                applied_employee: employee,
                applied_payroll_item: item,
                applied_to_payroll_at: Time.current
              )
            end
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
            Rails.logger.warn("apply_to_payroll validation failed for timecard #{timecard.id}: #{e.class}: #{e.message}")
            return render json: { error: e.message.presence || "Could not apply timecard to payroll" }, status: :unprocessable_entity
          rescue StandardError => e
            Rails.logger.error("apply_to_payroll failed for timecard #{timecard.id}: #{e.class}: #{e.message}")
            return render json: { error: "Failed to apply timecard to payroll" }, status: :unprocessable_entity
          end

          return render json: { error: multi_rate_error }, status: :unprocessable_entity if multi_rate_error

          unless item&.persisted?
            return render json: { error: "Could not apply timecard to payroll" }, status: :unprocessable_entity
          end

          item = PayrollItem.includes(employee: :department).find(item.id)

          unless item&.persisted? && timecard.reload.applied_payroll_item_id == item.id
            return render json: { error: "Could not apply timecard to payroll" }, status: :unprocessable_entity
          end

          render json: {
            employee_id: employee.id,
            employee_name: employee.full_name,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            timecard_id: timecard.id,
            payroll_item: payroll_item_json(item),
            timecard: timecard_json(timecard.reload)
          }
        end

        private

        def set_timecard
          @timecard = Timecard.find(params[:id])
          unless @timecard.company_id == current_company_id
            render json: { error: "Not found" }, status: :not_found
          end
        end

        def enqueue_ocr(timecard_id)
          OcrProcessJob.perform_later(timecard_id)
        rescue SolidQueue::Job::EnqueueError, ActiveRecord::StatementInvalid => e
          Rails.logger.error("Failed to enqueue OCR job for timecard #{timecard_id}: #{e.class}: #{e.message}")
          Timecard.where(id: timecard_id).update_all(
            ocr_status: Timecard.ocr_statuses[:failed],
            raw_ocr_response: { "error" => "Background job queue unavailable. Please contact support or retry later." }
          )
        end

        def timecard_params
          params.require(:timecard).permit(:employee_name, :period_start, :period_end, :pay_period_id)
        end

        def review_params
          params.fetch(:review, ActionController::Parameters.new).permit(:reviewed_by_name)
        end

        def header_changed?(timecard, attrs)
          attrs.any? { |key, value| timecard.public_send(key).to_s != value.to_s }
        end

        def find_or_match_employee(timecard)
          if params[:employee_id].present?
            return Employee.active.find_by(id: params[:employee_id], company_id: current_company_id)
          end

          return nil if timecard.employee_name.blank?

          employees = Employee.active.where(company_id: current_company_id)
          best = nil
          best_score = 0

          employees.each do |emp|
            score = trigram_similarity(timecard.employee_name, emp.full_name)
            if score > best_score
              best_score = score
              best = emp
            end
          end

          best_score >= 0.6 ? best : nil
        end

        def apply_timecard_hours_to_payroll_item(item, employee, total_hours)
          active_rates = employee.active_wage_rates.to_a
          rounded_hours = total_hours.round(2)
          uses_rate_selection = (employee.hourly? || employee.contractor_pay_type == "hourly") && active_rates.length > 1

          unless uses_rate_selection
            item.clear_wage_rate_hours!
            item.hours_worked = rounded_hours
            item.overtime_hours = 0
            item.holiday_hours = 0
            item.pto_hours = 0
            return nil
          end

          selected_rate_id = params[:wage_rate_id].presence&.to_i
          return "Choose which earning type these timecard hours should apply to." if selected_rate_id.blank?

          selected_rate = active_rates.find { |rate| rate.id == selected_rate_id }
          return "Selected earning type does not belong to this employee." unless selected_rate

          current_entries = item.wage_rate_hours
          active_rate_ids = active_rates.map(&:id)
          active_rate_labels = active_rates.map { |rate| rate.label.to_s.strip.downcase }
          inactive_entries = current_entries.reject do |entry|
            entry_rate_id = entry["employee_wage_rate_id"].presence&.to_i
            entry_label = entry["label"].to_s.strip.downcase
            (entry_rate_id.present? && active_rate_ids.include?(entry_rate_id)) ||
              (entry_rate_id.blank? && active_rate_labels.include?(entry_label))
          end
          entries_by_id = current_entries.index_by { |entry| entry["employee_wage_rate_id"].to_i if entry["employee_wage_rate_id"].present? }
          entries_by_label = current_entries.index_by { |entry| entry["label"].to_s.strip.downcase }

          active_entries = active_rates.map do |rate|
            existing = entries_by_id[rate.id] || entries_by_label[rate.label.to_s.strip.downcase] || {}
            entry = {
              employee_wage_rate_id: rate.id,
              label: rate.label,
              rate: rate.rate,
              regular_hours: existing["regular_hours"].to_f,
              overtime_hours: existing["overtime_hours"].to_f,
              holiday_hours: existing["holiday_hours"].to_f,
              pto_hours: existing["pto_hours"].to_f,
              is_primary: rate.is_primary,
              active: rate.active
            }
            if rate.id == selected_rate.id
              entry[:regular_hours] = rounded_hours
              entry[:overtime_hours] = 0
              entry[:holiday_hours] = 0
              entry[:pto_hours] = 0
            end
            entry
          end

          entries = inactive_entries + active_entries
          item.wage_rate_hours = entries
          item.hours_worked = entries.sum { |entry| entry_hours(entry, :regular_hours) }
          item.overtime_hours = entries.sum { |entry| entry_hours(entry, :overtime_hours) }
          item.holiday_hours = entries.sum { |entry| entry_hours(entry, :holiday_hours) }
          item.pto_hours = entries.sum { |entry| entry_hours(entry, :pto_hours) }
          nil
        end

        def entry_hours(entry, key)
          (entry[key] || entry[key.to_s]).to_f
        end

        def timecard_json(timecard)
          {
            id: timecard.id,
            company_id: timecard.company_id,
            pay_period_id: timecard.pay_period_id,
            employee_name: timecard.employee_name,
            period_start: timecard.period_start,
            period_end: timecard.period_end,
            image_url: TimecardOcr::StorageService.presigned_url(timecard.image_url),
            preprocessed_image_url: TimecardOcr::StorageService.presigned_url(timecard.preprocessed_image_url),
            ocr_status: timecard.ocr_status,
            overall_confidence: timecard.overall_confidence,
            ocr_error: timecard.raw_ocr_response.is_a?(Hash) ? timecard.raw_ocr_response["error"] : nil,
            reviewed_by_name: timecard.reviewed_by_name,
            reviewed_at: timecard.reviewed_at,
            applied_employee_id: timecard.applied_employee_id,
            applied_employee_name: timecard.applied_employee&.full_name,
            applied_payroll_item_id: timecard.applied_payroll_item_id,
            applied_to_payroll_at: timecard.applied_to_payroll_at,
            review_summary: TimecardOcr::ReviewSummary.build(timecard),
            created_at: timecard.created_at,
            punch_entries: timecard.punch_entries.map do |pe|
              {
                id: pe.id,
                card_day: pe.card_day,
                date: pe.date,
                day_of_week: pe.day_of_week,
                clock_in: pe.clock_in&.strftime("%H:%M"),
                lunch_out: pe.lunch_out&.strftime("%H:%M"),
                lunch_in: pe.lunch_in&.strftime("%H:%M"),
                clock_out: pe.clock_out&.strftime("%H:%M"),
                in3: pe.in3&.strftime("%H:%M"),
                out3: pe.out3&.strftime("%H:%M"),
                hours_worked: pe.hours_worked,
                confidence: pe.confidence,
                notes: pe.notes,
                manually_edited: pe.manually_edited,
                review_state: pe.review_state,
                reviewed_by_name: pe.reviewed_by_name,
                reviewed_at: pe.reviewed_at,
                needs_attention: pe.needs_attention?,
                blank_day: pe.blank_day?
              }
            end
          }
        end

        def payroll_item_json(item)
          {
            id: item.id,
            pay_period_id: item.pay_period_id,
            employee_id: item.employee_id,
            employee_name: item.employee_full_name,
            employment_type: item.employment_type,
            pay_rate: item.pay_rate,
            salary_override: item.salary_override,
            non_taxable_pay: item.non_taxable_pay,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            holiday_hours: item.holiday_hours,
            pto_hours: item.pto_hours,
            bonus: item.bonus,
            reported_tips: item.reported_tips,
            tips_paid_out: item.tips_paid_out,
            additional_withholding: item.additional_withholding,
            additional_withholding_override: item.additional_withholding_override,
            withholding_tax_adjustment: item.withholding_tax_adjustment,
            withholding_tax_override: item.withholding_tax_override,
            custom_earnings: item.custom_earnings || [],
            gross_pay: item.gross_pay,
            withholding_tax: item.withholding_tax,
            social_security_tax: item.social_security_tax,
            medicare_tax: item.medicare_tax,
            state_withheld: payroll_item_state_withheld(item),
            retirement_payment: item.retirement_payment,
            roth_retirement_payment: item.roth_retirement_payment,
            loan_payment: item.loan_payment,
            insurance_payment: item.insurance_payment,
            total_deductions: item.total_deductions,
            net_pay: item.net_pay,
            employer_social_security_tax: item.employer_social_security_tax,
            employer_medicare_tax: item.employer_medicare_tax,
            employer_retirement_match: item.employer_retirement_match,
            employer_roth_retirement_match: item.employer_roth_retirement_match,
            department_id: item.employee&.department_id,
            department_name: item.employee&.department&.name,
            check_number: item.check_number,
            check_printed_at: item.check_printed_at,
            check_print_count: item.check_print_count,
            check_status: item.check_status,
            loan_deduction: item.loan_deduction,
            tip_pool: item.tip_pool,
            import_source: item.import_source,
            custom_columns_data: item.custom_columns_data || {},
            voided: item.voided,
            voided_at: item.voided_at,
            void_reason: item.void_reason,
            reprint_of_check_number: item.reprint_of_check_number,
            ytd_gross: item.ytd_gross,
            ytd_net: item.ytd_net,
            ytd_withholding_tax: item.ytd_withholding_tax,
            ytd_social_security_tax: item.ytd_social_security_tax,
            ytd_medicare_tax: item.ytd_medicare_tax,
            ytd_retirement: item.ytd_retirement,
            ytd_roth_retirement: item.ytd_roth_retirement,
            created_at: item.created_at,
            updated_at: item.updated_at,
            wage_rate_hours: item.wage_rate_hours
          }
        end

        def payroll_item_state_withheld(item)
          return item.state_withheld if item.respond_to?(:state_withheld)

          item.custom_columns_data.is_a?(Hash) ? item.custom_columns_data["state_withheld"] : nil
        end
      end
    end
  end
end
