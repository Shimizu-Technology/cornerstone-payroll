# frozen_string_literal: true

require "digest"

module Api
  module V1
    module Admin
      class CheckPrintRunsController < BaseController
        before_action :set_pay_period, only: [ :queue, :index, :create ]
        before_action :set_run, only: [ :pdf, :confirm ]

        def queue
          render json: CheckPrintQueueService.new(pay_period: @pay_period).call
        rescue ArgumentError => e
          render json: { error: e.message }, status: :conflict
        end

        def index
          runs = @pay_period.check_print_runs
            .includes(:company, :created_by, :confirmed_by, :pay_period)
            .order(generated_at: :desc, id: :desc)
            .limit(50)

          render json: { check_print_runs: runs.map { |run| run_payload(run) } }
        end

        def create
          run = CheckPrintRunGenerationService.new(
            pay_period: @pay_period,
            actor: current_user,
            payroll_item_ids: params[:payroll_item_ids],
            non_employee_check_ids: params[:non_employee_check_ids],
            starting_slot: params[:starting_slot],
            ip_address: request.remote_ip
          ).call

          render json: { check_print_run: run_payload(run) }, status: :created
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error(
            "[check_print_runs#create] pay_period=#{@pay_period&.id} request_id=#{request.request_id} " \
            "#{e.class}: #{e.message}"
          )
          render json: {
            error: "The check package could not be generated. No checks were marked printed. Please try again."
          }, status: :service_unavailable
        end

        def pdf
          data = R2StorageService.new.download(@run.storage_key)
          return render json: { error: "The generated check package is unavailable" }, status: :not_found unless data
          unless data.bytesize == @run.byte_size && Digest::SHA256.hexdigest(data) == @run.sha256
            return render json: { error: "The generated check package failed its integrity check" }, status: :unprocessable_entity
          end

          send_data data,
                    filename: @run.filename,
                    type: "application/pdf",
                    disposition: params[:disposition] == "attachment" ? "attachment" : "inline"
        rescue StandardError => e
          Rails.logger.error(
            "[check_print_runs#pdf] run=#{@run&.id} request_id=#{request.request_id} " \
            "#{e.class}: #{e.message}"
          )
          render json: {
            error: "The generated check package could not be downloaded. Please try again."
          }, status: :service_unavailable
        end

        def confirm
          result = CheckPrintRunConfirmationService.new(
            run: @run,
            actor: current_user,
            ip_address: request.remote_ip
          ).call

          render json: {
            check_print_run: run_payload(result.fetch(:run)),
            already_confirmed: result.fetch(:already_confirmed),
            marked_printed: result.fetch(:marked_printed)
          }
        rescue CheckPrintRunConfirmationService::StaleSelectionError, ArgumentError => e
          render json: { error: e.message }, status: :conflict
        rescue StandardError => e
          Rails.logger.error(
            "[check_print_runs#confirm] run=#{@run&.id} request_id=#{request.request_id} " \
            "#{e.class}: #{e.message}"
          )
          render json: {
            error: "Print confirmation could not be recorded. No check print statuses were changed. Please try again."
          }, status: :service_unavailable
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
        end

        def set_run
          @run = CheckPrintRun.where(company_id: current_company_id).find(params[:id])
        end

        def run_payload(run)
          confirmation_state, confirmation_issue = confirmation_state_for(run)
          {
            id: run.id,
            pay_period_id: run.pay_period_id,
            status: run.status,
            check_stock_type: run.check_stock_type,
            starting_slot: run.starting_slot,
            selected_count: run.selected_count,
            manifest: run.manifest,
            filename: run.filename,
            sha256: run.sha256,
            byte_size: run.byte_size,
            generated_at: run.generated_at,
            confirmed_at: run.confirmed_at,
            created_by_id: run.created_by_id,
            created_by_name: run.created_by&.name,
            confirmed_by_id: run.confirmed_by_id,
            confirmed_by_name: run.confirmed_by&.name,
            requires_distinct_confirmer: run.company.require_distinct_check_print_confirmer?,
            can_current_user_confirm: !run.company.require_distinct_check_print_confirmer? || run.created_by_id != current_user.id,
            confirmation_state: confirmation_state,
            confirmation_issue: confirmation_issue
          }
        end

        def confirmation_state_for(run)
          return [ "confirmed", nil ] if run.confirmed?

          CheckPrintRunSelectionVerifier.new(run: run).call
          [ "ready", nil ]
        rescue CheckPrintRunSelectionVerifier::StaleSelectionError => e
          [ "stale", e.message ]
        end
      end
    end
  end
end
