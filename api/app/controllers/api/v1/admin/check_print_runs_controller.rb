# frozen_string_literal: true

require "digest"

module Api
  module V1
    module Admin
      class CheckPrintRunsController < BaseController
        before_action :set_pay_period, only: [ :queue, :create ]
        before_action :set_run, only: [ :pdf, :confirm ]

        def queue
          render json: CheckPrintQueueService.new(pay_period: @pay_period).call
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
        rescue R2StorageService::DownloadError => e
          render json: { error: e.message }, status: :service_unavailable
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
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
        end

        def set_run
          @run = CheckPrintRun.where(company_id: current_company_id).find(params[:id])
        end

        def run_payload(run)
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
            confirmed_at: run.confirmed_at
          }
        end
      end
    end
  end
end
