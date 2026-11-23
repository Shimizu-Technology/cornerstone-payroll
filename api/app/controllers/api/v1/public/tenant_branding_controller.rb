# frozen_string_literal: true

module Api
  module V1
    module Public
      class TenantBrandingController < ActionController::API
        def show
          response.headers["Cache-Control"] = "no-store"

          host = params[:host]
          slug = params[:slug]
          branding = TenantSubdomainRegistry.branding_for(host: host, slug: slug) if host.nil? ^ slug.nil?

          return head :not_found unless branding

          render json: branding
        end
      end
    end
  end
end
