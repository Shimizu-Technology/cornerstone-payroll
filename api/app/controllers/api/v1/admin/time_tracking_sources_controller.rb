# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimeTrackingSourcesController < BaseController
        before_action :require_admin!, except: [ :index, :show ]
        before_action :set_source, only: [ :show, :update, :destroy, :test_connection ]
        before_action :disable_http_caching

        def index
          sources = TimeTrackingSource.where(company_id: current_company_id).order(:name)
          render json: { time_tracking_sources: sources.map { |source| source_json(source) } }
        end

        def show
          render json: { time_tracking_source: source_json(@source) }
        end

        def create
          source = TimeTrackingSource.new(source_params.merge(company_id: current_company_id))
          TimeTrackingSource.transaction do
            deactivate_other_sources! if source.active?
            source.save!
          end
          render json: { time_tracking_source: source_json(source) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render_one_active_source_error
        end

        def update
          TimeTrackingSource.transaction do
            @source.assign_attributes(source_params)
            deactivate_other_sources!(except: @source) if @source.active?
            @source.save!
          end
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

          render json: {
            ok: true,
            message: "Connected to #{@source.name}.",
            source: payload["source"],
            generated_at: payload["generated_at"],
            employee_count: Array(payload["employees"]).size,
            summary: payload["summary"] || {}
          }
        rescue TimeTracking::Client::Error, ArgumentError, SocketError, SystemCallError, Timeout::Error,
               Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
          render json: { ok: false, error: "Connection test failed: #{e.message}" }, status: :unprocessable_entity
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
          permitted = [ :name, :base_url, :shared_secret, :active ]
          permitted << :source_type if action_name == "create"
          params.require(:time_tracking_source).permit(*permitted)
        end

        def deactivate_other_sources!(except: nil)
          scope = TimeTrackingSource.where(company_id: current_company_id, active: true)
          scope = scope.where.not(id: except.id) if except&.persisted?
          scope.update_all(active: false, updated_at: Time.current)
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
            last_synced_at: source.last_synced_at,
            created_at: source.created_at,
            updated_at: source.updated_at
          }
        end
      end
    end
  end
end
