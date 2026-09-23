# frozen_string_literal: true

require "digest"

module Api
  module V1
    module Admin
      class CheckPrintGenerationsController < BaseController
        before_action :set_pay_period
        before_action :set_generation, only: :show

        def create
          attributes = generation_attributes
          request_digest = Digest::SHA256.hexdigest(JSON.generate(attributes))
          generation, created = find_or_create_generation(attributes, request_digest)

          if generation.request_digest != request_digest
            return render json: {
              error: "This generation key was already used for a different check selection. Start a new package."
            }, status: :conflict
          end

          enqueue_generation(generation) if created
          render json: { check_print_generation: generation_payload(generation) }, status: :accepted
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => e
          generation&.fail_safely!(
            code: "queue_unavailable",
            message: "Generation could not be started. Your selection is unchanged; try again."
          )
          Rails.logger.error(
            "[check_print_generations#create] pay_period=#{@pay_period&.id} request_id=#{request.request_id} " \
            "#{e.class}: #{e.message}"
          )
          render json: {
            error: "Generation could not be started. Your selection is unchanged; try again."
          }, status: :service_unavailable
        end

        def show
          render json: { check_print_generation: generation_payload(@generation) }
        end

        def active
          generation = scoped_generations.active.order(created_at: :desc, id: :desc).first
          render json: {
            check_print_generation: generation ? generation_payload(generation) : nil
          }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
        end

        def set_generation
          @generation = scoped_generations.find(params[:id])
        end

        def scoped_generations
          @pay_period.check_print_generations.where(
            company_id: current_company_id,
            requested_by_id: current_user.id
          )
        end

        def generation_attributes
          idempotency_key = params[:idempotency_key].to_s.strip
          raise ArgumentError, "A generation key is required" if idempotency_key.blank?
          raise ArgumentError, "The generation key is invalid" if idempotency_key.length > 255

          payroll_item_ids = normalize_ids(params[:payroll_item_ids])
          non_employee_check_ids = normalize_ids(params[:non_employee_check_ids])
          total_items = payroll_item_ids.size + non_employee_check_ids.size
          raise ArgumentError, "Select at least one printable check" if total_items.zero?

          starting_slot = Integer(params[:starting_slot] || 1)
          raise ArgumentError, "Starting slot must be a number from 1 through 4" unless (1..4).cover?(starting_slot)

          printer_profile_id = Integer(params[:printer_profile_id])
          printer_profile_lock_version = Integer(params[:printer_profile_lock_version])
          profile = current_company.organization.printer_profiles.active.find(printer_profile_id)
          unless profile.check_stock_type == current_company.check_stock_type
            raise ArgumentError,
              "#{profile.name} is calibrated for #{profile.check_stock_type.humanize}, not #{current_company.check_stock_type.humanize}"
          end

          {
            "idempotency_key" => idempotency_key,
            "payroll_item_ids" => payroll_item_ids,
            "non_employee_check_ids" => non_employee_check_ids,
            "starting_slot" => starting_slot,
            "printer_profile_id" => profile.id,
            "printer_profile_lock_version" => printer_profile_lock_version,
            "total_items" => total_items
          }
        rescue ActiveRecord::RecordNotFound
          raise ArgumentError, "Choose an active printer profile before generating checks"
        rescue TypeError
          raise ArgumentError, "Printer profile and starting slot values are required"
        end

        def normalize_ids(values)
          Array(values).filter_map do |value|
            parsed = Integer(value)
            parsed if parsed.positive?
          rescue ArgumentError, TypeError
            nil
          end.uniq.sort
        end

        def find_or_create_generation(attributes, request_digest)
          key_scope = CheckPrintGeneration.where(
            company_id: current_company_id,
            requested_by_id: current_user.id,
            idempotency_key: attributes.fetch("idempotency_key")
          )
          existing = key_scope.first
          return [ existing, false ] if existing

          generation = CheckPrintGeneration.create!(
            company: current_company,
            pay_period: @pay_period,
            requested_by: current_user,
            printer_profile_id: attributes.fetch("printer_profile_id"),
            idempotency_key: attributes.fetch("idempotency_key"),
            request_digest: request_digest,
            payroll_item_ids: attributes.fetch("payroll_item_ids"),
            non_employee_check_ids: attributes.fetch("non_employee_check_ids"),
            printer_profile_lock_version: attributes.fetch("printer_profile_lock_version"),
            starting_slot: attributes.fetch("starting_slot"),
            request_ip: request.remote_ip,
            total_items: attributes.fetch("total_items")
          )
          [ generation, true ]
        rescue ActiveRecord::RecordNotUnique
          [ key_scope.first!, false ]
        end

        def enqueue_generation(generation)
          CheckPrintGenerationJob.perform_later(generation.id)
        end

        def generation_payload(generation)
          {
            id: generation.id,
            pay_period_id: generation.pay_period_id,
            status: generation.status,
            phase: generation.phase,
            completed_items: generation.completed_items,
            total_items: generation.total_items,
            error_code: generation.error_code,
            error_message: generation.error_message,
            check_print_run_id: generation.check_print_run_id,
            created_at: generation.created_at,
            started_at: generation.started_at,
            completed_at: generation.completed_at,
            failed_at: generation.failed_at
          }
        end
      end
    end
  end
end
