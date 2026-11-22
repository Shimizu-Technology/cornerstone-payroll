# frozen_string_literal: true

class TenantSubdomainRegistry
  ROOT_DOMAIN = "shimizu-technology.com"
  SLUG_PATTERN = /\A[a-z0-9][a-z0-9-]{1,38}[a-z0-9]\z/
  HOST_PATTERN = /\A([a-z0-9-]+)\.#{Regexp.escape(ROOT_DOMAIN)}\z/
  ORIGIN_PATTERN = /\Ahttps:\/\/([a-z0-9-]+)\.#{Regexp.escape(ROOT_DOMAIN)}\z/
  RESERVED_SLUGS = %w[payroll api clerk accounts www staging mail admin app my status docs support tax aire-api shimizu].freeze

  def self.client_origin?(normalized_origin)
    slug = normalized_origin&.match(%r{\Ahttps?://([a-z0-9-]+)\.#{Regexp.escape(ROOT_DOMAIN)}(?::\d+)?\z})&.[](1)
    slug.present? && !RESERVED_SLUGS.include?(slug)
  end

  def self.allowed_origin?(origin)
    slug = origin.match(ORIGIN_PATTERN)&.[](1)
    slug.present? && enabled_company(slug).present?
  end

  def self.branding_for(host: nil, slug: nil)
    slug = host.match(HOST_PATTERN)&.[](1) if host.is_a?(String) && slug.nil?
    company = enabled_company(slug)
    return unless company

    branding = company.branding.is_a?(Hash) ? company.branding : {}
    {
      name: company.name,
      logo_url: https_url(branding["logo_url"]),
      primary_color: hex_color(branding["primary_color"]),
      accent_color: hex_color(branding["accent_color"])
    }
  end

  def self.enabled_company(slug)
    return unless slug.is_a?(String) && SLUG_PATTERN.match?(slug) && !RESERVED_SLUGS.include?(slug)

    # Rails caches these reads only for the current executor run. A later
    # request reads the committed company and effective profile again, even
    # when the change was made by another process or the business date rolled.
    company = Company.active.live_payroll.where("lower(subdomain_slug) = ?", slug).find_by(subdomain_slug: slug)
    company if company && CompanyFeatures.for(company).subdomain_enabled?
  end
  private_class_method :enabled_company

  def self.https_url(value)
    return unless value.is_a?(String)

    uri = URI.parse(value)
    value if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end
  private_class_method :https_url

  def self.hex_color(value)
    value if value.is_a?(String) && value.match?(/\A#[a-f0-9]{6}\z/i)
  end
  private_class_method :hex_color
end
