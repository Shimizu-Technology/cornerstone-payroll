# frozen_string_literal: true

module Api
  module V1
    module Public
      class TenantBrandingController < ActionController::API
        def show
          response.headers["Cache-Control"] = "no-store"

          host = params[:host]
          slug = params[:slug]
          if host.nil? ^ slug.nil?
            branding = TenantSubdomainRegistry.branding_for(host: host, slug: slug, logo_base_url: request.base_url)
          end

          return head :not_found unless branding

          render json: branding
        end

        # An enabled company's uploaded logo, by content fingerprint. The
        # address changes when the logo does, so it can be cached for good.
        def logo
          digest, extension = params[:file].to_s.split(".", 2)
          company = TenantSubdomainRegistry.logo_company_for(slug: params[:slug], digest: digest)
          return head :not_found unless company && company.brand_logo_extension == extension

          bytes = TenantLogoStorageService.new.download(company)
          return head :not_found unless bytes

          response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
          response.headers["X-Content-Type-Options"] = "nosniff"
          # An SVG opened directly is a document on the API's origin. It can't
          # run scripts or load anything.
          response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox"
          response.headers["Cross-Origin-Resource-Policy"] = "cross-origin"
          send_data bytes, type: company.brand_logo_content_type, disposition: "inline"
        end
      end
    end
  end
end
