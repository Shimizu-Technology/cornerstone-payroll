# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayComponentTaxRulesController < BaseController
        include Auditable
        before_action :require_manager_or_admin!, only: [ :create, :update ]
        before_action :set_rule, only: :update

        def index
          effective_on = parse_effective_on
          configured = PayComponentTaxRule.for_company_or_global(current_company_id)
            .order(:component_key, :effective_from, :id)
          snapshot = PayComponentRuleSnapshotBuilder.new(
            company: current_company,
            effective_on: effective_on
          ).call

          render json: {
            effective_on: effective_on,
            effective_rule_snapshot: snapshot,
            configured_rules: configured.map { |rule| rule_json(rule) }
          }
        end

        def create
          rule = current_company.pay_component_tax_rules.new(rule_params)
          rule.approved_by = current_user
          rule.approved_at = Time.current
          rule.save!

          render json: { pay_component_tax_rule: rule_json(rule) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def update
          if @rule.immutable_after_use?
            return render json: {
              error: "This rule has been used by committed payroll. Create a new effective-dated version instead."
            }, status: :unprocessable_entity
          end

          @rule.assign_attributes(rule_params)
          @rule.approved_by = current_user
          @rule.approved_at = Time.current
          @rule.save!

          render json: { pay_component_tax_rule: rule_json(@rule) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::ReadOnlyRecord
          render json: {
            error: "This rule has been used by committed payroll. Create a new effective-dated version instead."
          }, status: :unprocessable_entity
        end

        private

        def set_rule
          @rule = current_company.pay_component_tax_rules.find(params[:id])
        end

        def parse_effective_on
          return Date.current if params[:effective_on].blank?

          Date.iso8601(params[:effective_on].to_s)
        rescue Date::Error
          raise ActionController::BadRequest, "effective_on must be a valid YYYY-MM-DD date"
        end

        def rule_params
          params.require(:pay_component_tax_rule).permit(
            :component_key, :display_name, :component_kind,
            :fit_treatment, :social_security_treatment, :medicare_treatment,
            :additional_medicare_treatment, :swica_treatment,
            :retirement_treatment, :reimbursement_treatment,
            :register_presentation, :gl_account_code,
            :effective_from, :effective_to, :source_name, :source_url,
            :version, :active,
            w2_gu_mapping: {}, form_941_mapping: {}
          )
        end

        def rule_json(rule)
          rule.snapshot.merge(
            "active" => rule.active,
            "approved_by_id" => rule.approved_by_id,
            "approved_by_name" => rule.approved_by&.name,
            "immutable_after_use" => rule.immutable_after_use?,
            "created_at" => rule.created_at,
            "updated_at" => rule.updated_at
          )
        end
      end
    end
  end
end
