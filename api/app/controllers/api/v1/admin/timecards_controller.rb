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
            timecards = timecards.where("employee_name ILIKE ?", "%#{params[:search]}%")
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
              run_ocr!(existing) if existing.failed?
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
            run_ocr!(timecard)
            timecard
          end

          render json: timecards.map { |tc| timecard_json(tc.reload) }
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

          if @timecard.overall_confidence.to_f < 0.7
            return render json: { error: "OCR confidence is too low. Re-run OCR or verify flagged rows first." }, status: :unprocessable_entity
          end

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

          run_ocr!(@timecard)
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

          item = pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)
          if item.new_record?
            item.company_id = current_company_id
            item.employment_type = employee.employment_type
            item.pay_rate = employee.primary_wage_rate&.rate || employee.pay_rate
          end

          item.hours_worked = total_hours.round(2)
          item.import_source = "timecard_ocr"
          item.save!

          render json: {
            employee_id: employee.id,
            employee_name: employee.full_name,
            hours_worked: item.hours_worked,
            overtime_hours: item.overtime_hours,
            timecard_id: timecard.id
          }
        end

        private

        def set_timecard
          @timecard = Timecard.find(params[:id])
          unless @timecard.company_id == current_company_id
            render json: { error: "Not found" }, status: :not_found
          end
        end

        def timecard_params
          params.require(:timecard).permit(:employee_name, :period_start, :period_end, :pay_period_id)
        end

        def review_params
          params.fetch(:review, ActionController::Parameters.new).permit(:reviewed_by_name)
        end

        def run_ocr!(timecard)
          timecard.update!(ocr_status: :processing)

          result = TimecardOcr::OcrService.process(timecard)
          entries = Array(result["entries"])
          raise "OCR returned no entries" if entries.empty?

          timecard.transaction do
            timecard.punch_entries.delete_all

            timecard.update!(
              employee_name: result["employee_name"],
              period_start: result["period_start"],
              period_end: result["period_end"],
              overall_confidence: result["overall_confidence"],
              preprocessed_image_url: result["preprocessed_image_key"],
              raw_ocr_response: result
            )

            entries.each do |entry|
              timecard.punch_entries.create!(
                card_day: entry["card_day"],
                date: entry["date"],
                day_of_week: entry["day_of_week"],
                clock_in: entry["clock_in"],
                lunch_out: entry["lunch_out"],
                lunch_in: entry["lunch_in"],
                clock_out: entry["clock_out"],
                in3: entry["in3"],
                out3: entry["out3"],
                confidence: entry["confidence"],
                notes: entry["notes"]
              )
            end

            timecard.update!(ocr_status: :complete)
          end
        rescue => e
          Rails.logger.error("OCR failed for timecard #{timecard.id}: #{e.class}: #{e.message}")
          timecard.update!(
            ocr_status: :failed,
            raw_ocr_response: { "error" => e.message }
          )
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
      end
    end
  end
end
