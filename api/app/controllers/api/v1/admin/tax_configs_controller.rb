# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TaxConfigsController < ApplicationController
        before_action :set_tax_config, only: [ :show, :update, :destroy, :activate, :audit_logs ]

        # GET /api/v1/admin/tax_configs
        def index
          @configs = AnnualTaxConfig.includes(
            filing_status_configs: :tax_brackets
          ).order(tax_year: :desc)

          render json: {
            tax_configs: @configs.map { |c| serialize_config(c) }
          }
        end

        # GET /api/v1/admin/tax_configs/:id
        def show
          render json: {
            tax_config: serialize_config(@config, include_brackets: true)
          }
        end

        # POST /api/v1/admin/tax_configs
        # Creates a new tax year config, optionally copying from previous year
        def create
          if params[:copy_from_year]
            @config = AnnualTaxConfig.create_from_previous(
              params[:tax_year].to_i,
              source_year: params[:copy_from_year].to_i
            )
          else
            @config = AnnualTaxConfig.new(config_params)
            @config.save!
          end

          TaxConfigAuditLog.log_created(@config, user_id: current_user_id, ip_address: request.remote_ip)

          render json: {
            tax_config: serialize_config(@config, include_brackets: true),
            message: "Tax configuration for #{@config.tax_year} created successfully"
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/tax_configs/:id
        def update
          changes = track_changes(@config, config_params)

          if @config.update(config_params)
            # Log each changed field
            changes.each do |field, (old_val, new_val)|
              TaxConfigAuditLog.log_updated(
                @config,
                field_name: field,
                old_value: old_val,
                new_value: new_val,
                user_id: current_user_id,
                ip_address: request.remote_ip
              )
            end

            render json: {
              tax_config: serialize_config(@config, include_brackets: true),
              message: "Tax configuration updated"
            }
          else
            render json: { error: @config.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/tax_configs/:id
        def destroy
          if @config.is_active
            render json: { error: "Cannot delete the active tax configuration" }, status: :unprocessable_entity
            return
          end

          @config.destroy
          render json: { message: "Tax configuration for #{@config.tax_year} deleted" }
        end

        # POST /api/v1/admin/tax_configs/:id/activate
        def activate
          old_active = AnnualTaxConfig.find_by(is_active: true)

          @config.activate!

          TaxConfigAuditLog.log_deactivated(old_active, user_id: current_user_id, ip_address: request.remote_ip) if old_active && old_active != @config
          TaxConfigAuditLog.log_activated(@config, user_id: current_user_id, ip_address: request.remote_ip)

          render json: {
            tax_config: serialize_config(@config),
            message: "#{@config.tax_year} is now the active tax configuration"
          }
        end

        # GET /api/v1/admin/tax_configs/:id/audit_logs
        def audit_logs
          logs = @config.audit_logs.order(created_at: :desc).limit(100)

          render json: {
            audit_logs: logs.map { |log| serialize_audit_log(log) }
          }
        end

        # PATCH /api/v1/admin/tax_configs/:id/filing_status/:filing_status
        def update_filing_status
          @config = AnnualTaxConfig.find(params[:id])
          fsc = @config.filing_status_configs.find_by!(filing_status: params[:filing_status])

          old_std_deduction = fsc.standard_deduction

          if fsc.update(filing_status_params)
            if old_std_deduction != fsc.standard_deduction
              TaxConfigAuditLog.log_updated(
                @config,
                field_name: "#{params[:filing_status]}_standard_deduction",
                old_value: old_std_deduction,
                new_value: fsc.standard_deduction,
                user_id: current_user_id,
                ip_address: request.remote_ip
              )
            end

            render json: {
              filing_status_config: serialize_filing_status(fsc),
              message: "Filing status config updated"
            }
          else
            render json: { error: fsc.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/tax_configs/:id/brackets/:filing_status
        def update_brackets
          @config = AnnualTaxConfig.find(params[:id])
          fsc = @config.filing_status_configs.find_by!(filing_status: params[:filing_status])

          ActiveRecord::Base.transaction do
            params[:brackets].each do |bracket_data|
              bracket = fsc.tax_brackets.find_by!(bracket_order: bracket_data[:bracket_order])
              bracket.update!(
                min_income: bracket_data[:min_income],
                max_income: bracket_data[:max_income],
                rate: bracket_data[:rate]
              )
            end
          end

          TaxConfigAuditLog.log_updated(
            @config,
            field_name: "#{params[:filing_status]}_brackets",
            old_value: "multiple brackets",
            new_value: "updated",
            user_id: current_user_id,
            ip_address: request.remote_ip
          )

          render json: {
            filing_status_config: serialize_filing_status(fsc, include_brackets: true),
            message: "Tax brackets updated"
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_tax_config
          @config = AnnualTaxConfig.includes(filing_status_configs: :tax_brackets).find(params[:id])
        end

        def config_params
          params.permit(:tax_year, :ss_wage_base, :ss_rate, :medicare_rate,
                        :additional_medicare_rate, :additional_medicare_threshold)
        end

        def filing_status_params
          params.permit(:standard_deduction)
        end

        def current_user_id
          # TODO: Get from WorkOS auth
          nil
        end

        def track_changes(record, new_params)
          changes = {}
          new_params.each do |key, value|
            old_value = record.send(key)
            changes[key] = [ old_value, value ] if old_value.to_s != value.to_s
          end
          changes
        end

        def serialize_config(config, include_brackets: false)
          {
            id: config.id,
            tax_year: config.tax_year,
            ss_wage_base: config.ss_wage_base.to_f,
            ss_rate: config.ss_rate.to_f,
            medicare_rate: config.medicare_rate.to_f,
            additional_medicare_rate: config.additional_medicare_rate.to_f,
            additional_medicare_threshold: config.additional_medicare_threshold.to_f,
            is_active: config.is_active,
            created_at: config.created_at,
            updated_at: config.updated_at,
            filing_statuses: config.filing_status_configs.map { |fsc| serialize_filing_status(fsc, include_brackets: include_brackets) }
          }
        end

        def serialize_filing_status(fsc, include_brackets: false)
          data = {
            id: fsc.id,
            filing_status: fsc.filing_status,
            standard_deduction: fsc.standard_deduction.to_f
          }

          if include_brackets
            data[:brackets] = fsc.tax_brackets.map { |b| serialize_bracket(b) }
          end

          data
        end

        def serialize_bracket(bracket)
          {
            id: bracket.id,
            bracket_order: bracket.bracket_order,
            min_income: bracket.min_income.to_f,
            max_income: bracket.max_income&.to_f,
            rate: bracket.rate.to_f,
            rate_percent: (bracket.rate * 100).round(1)
          }
        end

        def serialize_audit_log(log)
          {
            id: log.id,
            action: log.action,
            field_name: log.field_name,
            old_value: log.old_value,
            new_value: log.new_value,
            user_id: log.user_id,
            ip_address: log.ip_address,
            created_at: log.created_at
          }
        end
      end
    end
  end
end
