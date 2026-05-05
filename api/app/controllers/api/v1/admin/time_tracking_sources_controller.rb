# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimeTrackingSourcesController < BaseController
        before_action :set_source, only: [ :show, :update, :destroy ]

        def index
          sources = TimeTrackingSource.where(company_id: current_company_id).order(:name)
          render json: { time_tracking_sources: sources.map { |source| source_json(source) } }
        end

        def show
          render json: { time_tracking_source: source_json(@source) }
        end

        def create
          source = TimeTrackingSource.new(source_params.merge(company_id: current_company_id))
          if source.save
            render json: { time_tracking_source: source_json(source) }, status: :created
          else
            render json: { errors: source.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @source.update(source_params)
            render json: { time_tracking_source: source_json(@source) }
          else
            render json: { errors: @source.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @source.update!(active: false)
          head :no_content
        end

        private

        def set_source
          @source = TimeTrackingSource.find_by!(id: params[:id], company_id: current_company_id)
        end

        def source_params
          permitted = [ :name, :base_url, :shared_secret, :active ]
          permitted << :source_type if action_name == "create"
          params.require(:time_tracking_source).permit(*permitted)
        end

        def source_json(source)
          {
            id: source.id,
            company_id: source.company_id,
            name: source.name,
            source_type: source.source_type,
            base_url: source.base_url,
            active: source.active,
            last_synced_at: source.last_synced_at,
            created_at: source.created_at,
            updated_at: source.updated_at
          }
        end
      end
    end
  end
end
