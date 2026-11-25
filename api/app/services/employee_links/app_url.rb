# frozen_string_literal: true

module EmployeeLinks
  # Where an employee signs up: the company's enabled client subdomain, or the
  # shared EMPLOYEE_APP_URL. Secrets travel in the URL fragment, which browsers
  # never send to a server or put in a Referer header.
  module AppUrl
    module_function

    # Reads the company's own profile rather than the subdomain registry, which
    # opens a system scope and so can't run inside a staff company scope.
    def origin_for(company)
      if subdomain_live?(company)
        return "https://#{company.subdomain_slug}.#{TenantSubdomainRegistry::ROOT_DOMAIN}"
      end

      TenantSubdomainRegistry.https_url(ENV["EMPLOYEE_APP_URL"].to_s.strip.delete_suffix("/")).presence
    end

    def subdomain_live?(company)
      slug = company.subdomain_slug
      slug.present? && TenantSubdomainRegistry::SLUG_PATTERN.match?(slug) &&
        !TenantSubdomainRegistry::RESERVED_SLUGS.include?(slug) && company.active? && company.live_payroll? &&
        company.organization.active? && CompanyFeatures.for(company).subdomain_enabled?
    end

    def entry_url(company, path:)
      origin = origin_for(company)
      return unless origin

      page = { "claim" => "claim", "reactivate" => "reactivate" }.fetch(path, "activate")
      "#{origin}/#{page}"
    end

    def invite_url(company, path:, secret:)
      url = entry_url(company, path: path)
      "#{url}#token=#{CGI.escape(secret)}" if url
    end

    def sign_up_redirect_url(company)
      origin = origin_for(company)
      "#{origin}/sign-up" if origin
    end
  end
end
