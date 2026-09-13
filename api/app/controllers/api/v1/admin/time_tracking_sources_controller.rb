# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimeTrackingSourcesController < BaseController
        before_action :require_admin!, except: [ :index, :show, :save_delegation, :destroy_delegation ]
        before_action :set_source, only: [ :show, :update, :destroy, :test_connection, :save_delegation, :destroy_delegation ]
        before_action :disable_http_caching

        def index
          sources = TimeTrackingSource.where(company_id: current_company_id).includes(:time_tracking_delegations).order(:name)
          render json: { time_tracking_sources: sources.map { |source| source_json(source) } }
        end

        def show
          render json: { time_tracking_source: source_json(@source) }
        end

        def create
          source = source_configuration.save!(source_params)
          render json: { time_tracking_source: source_json(source) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render_one_active_source_error
        end

        def update
          source_configuration(@source).save!(source_params)
          render json: { time_tracking_source: source_json(@source) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render_one_active_source_error
        end

        def test_connection
          unless @source.shared_secret_configured?
            render json: {
              ok: false,
              error: "Shared secret is not configured in Payroll. Paste the source app's PAYROLL_SHARED_SECRET, save the source, then test again."
            }, status: :unprocessable_entity
            return
          end

          payload = TimeTracking::Client.new(@source).time_summary(
            start_date: test_connection_date,
            end_date: test_connection_date
          )
          cockpit_ready = if @source.source_type == "aire_services"
            begin
              TimeTracking::Client.new(@source).payroll_cockpit_employees(per_page: 1).key?("employees")
            rescue TimeTracking::Client::Error
              false
            end
          else
            false
          end

          render json: {
            ok: true,
            message: "Connected to #{@source.name}.",
            source: payload["source"],
            generated_at: payload["generated_at"],
            employee_count: Array(payload["employees"]).size,
            summary: payload["summary"] || {},
            cockpit_ready: cockpit_ready,
            delegation_token_configured: @source.delegation_for(current_user).present?
          }
        rescue TimeTracking::Client::Error, ArgumentError, SocketError, SystemCallError, Timeout::Error,
               Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
          render json: { ok: false, error: "Connection test failed: #{e.message}" }, status: :unprocessable_entity
        end

        def save_delegation
          token = params.permit(:delegation_token)[:delegation_token].to_s.strip
          source_configuration(@source).save_delegation!(token)
          render json: { time_tracking_source: source_json(@source) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        def destroy_delegation
          source_configuration(@source).remove_delegation!
          render json: { time_tracking_source: source_json(@source) }
        end

        def destroy
          @source.update!(active: false)
          head :no_content
        end

        private

        def disable_http_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end

        def set_source
          @source = TimeTrackingSource.find_by!(id: params[:id], company_id: current_company_id)
        end

        def source_params
          permitted = [ :name, :base_url, :shared_secret, :delegation_token, :active ]
          permitted << :source_type if action_name == "create"
          params.require(:time_tracking_source).permit(*permitted)
        end

        def source_configuration(source = nil)
          TimeTracking::SourceConfigurationService.new(
            company_id: current_company_id,
            actor: current_user,
            source: source
          )
        end

        def test_connection_date
          Date.current.iso8601
        end

        def render_one_active_source_error
          render json: { errors: [ "Company can only have one active time tracking source" ] }, status: :unprocessable_entity
        end

        def source_json(source)
          {
            id: source.id,
            company_id: source.company_id,
            name: source.name,
            source_type: source.source_type,
            base_url: source.base_url,
            active: source.active,
            shared_secret_configured: source.shared_secret_configured?,
            delegation_token_configured: source.delegation_for(current_user).present?,
            last_synced_at: source.last_synced_at,
            created_at: source.created_at,
            updated_at: source.updated_at
          }
        end
      end
    end
  end
end
