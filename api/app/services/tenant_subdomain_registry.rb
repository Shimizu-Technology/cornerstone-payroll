# frozen_string_literal: true

class TenantSubdomainRegistry
  ROOT_DOMAIN = "shimizu-technology.com"
  SLUG_PATTERN = /\A(?!xn--)[a-z0-9][a-z0-9-]{1,38}[a-z0-9]\z/
  HOST_PATTERN = /\A([a-z0-9-]+)\.#{Regexp.escape(ROOT_DOMAIN)}\z/
  ORIGIN_PATTERN = /\Ahttps:\/\/([a-z0-9-]+)\.#{Regexp.escape(ROOT_DOMAIN)}\z/
  CLIENT_ORIGIN_PATTERN = %r{\Ahttps?://(?:[^/?#@]*@)?([^./?#:]+)\.#{Regexp.escape(ROOT_DOMAIN)}\.?(?=[:/?#]|\z)}i
  RESERVED_SLUGS = %w[payroll api clerk clkmail accounts www staging mail admin app my status docs support tax aire aire-api plane shimizu].freeze
  BRANDING_PATH = %r{\A/api/v1/public/tenant_branding/?\z}
  PORTAL_PATH = %r{\A/api/v1/(?:auth|employee)/}
  BRANDING_METHODS = %w[GET HEAD OPTIONS].freeze
  BRANDING_KEYS = %w[logo_url primary_color accent_color].freeze
  CACHE_TTL = 45.seconds

  PUBLIC_LOGO_HOST = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*\z/i
  PRIVATE_LOGO_HOST = /(?:\A|\.)(?:localhost|local|localdomain|internal|lan|home\.arpa|r2\.cloudflarestorage\.com)\z|(?:\A|\.)s3[^.]*(?:\.[^.]+)*\.amazonaws\.com(?:\.cn)?\z/i

  @cache_version = 0
  CACHE_VERSION_LOCK = Mutex.new

  # Recognize malformed variants of tenant origins too, so they cannot fall
  # back to the static allowlist or the pre-cutover Clerk behavior.
  def self.client_origin?(origin)
    return false unless origin.is_a?(String)

    slug = origin.strip.match(CLIENT_ORIGIN_PATTERN)&.[](1)
    slug.present? && !RESERVED_SLUGS.include?(slug.downcase)
  end

  def self.allowed_origin?(origin)
    enabled_origin_company_id(origin).present?
  end

  def self.enabled_origin_company_id(origin)
    return unless origin.is_a?(String)

    enabled_company_id(origin.match(ORIGIN_PATTERN)&.[](1))
  end

  def self.branding_for(host: nil, slug: nil)
    slug = host.match(HOST_PATTERN)&.[](1) if host.is_a?(String) && slug.nil?
    company_id = enabled_company_id(slug)
    return unless company_id

    company = live_companies.find_by(id: company_id, subdomain_slug: slug)
    return unless company

    branding = company.branding.is_a?(Hash) ? company.branding : {}
    {
      name: company.name,
      logo_url: https_url(branding["logo_url"]),
      primary_color: hex_color(branding["primary_color"]),
      accent_color: hex_color(branding["accent_color"])
    }
  end

  def self.invalidate!
    # Version entries so a cache fill concurrent with a commit cannot make
    # an earlier registry visible to subsequent requests.
    CACHE_VERSION_LOCK.synchronize { @cache_version += 1 }
  end

  def self.cors_path(path)
    unescaped = Rack::Utils.unescape_path(path)
    Rack::Utils.clean_path_info(unescaped) if Rack::Utils.valid_path?(unescaped)
  end

  def self.https_url(value)
    return unless value.is_a?(String)

    uri = URI.parse(value)
    return unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

    host = uri.host&.delete_suffix(".")
    value if PUBLIC_LOGO_HOST.match?(host.to_s) && !PRIVATE_LOGO_HOST.match?(host)
  rescue URI::InvalidURIError
    nil
  end

  def self.hex_color(value)
    value if value.is_a?(String) && value.match?(/\A#[a-f0-9]{6}\z/i)
  end

  def self.enabled_company_id(slug)
    return unless slug.is_a?(String) && SLUG_PATTERN.match?(slug) && !RESERVED_SLUGS.include?(slug)

    date = PayrollBusinessClock.today
    version = CACHE_VERSION_LOCK.synchronize { @cache_version.to_s }
    companies_by_slug = RequestPathCache.store.fetch([ "tenant-subdomains", date.iso8601 ], version: version, expires_in: CACHE_TTL) do
      # Read the same effective dates as ClientOperatingProfile.for_date in a
      # single query. A company without a persisted profile starts off.
      ClientOperatingProfile.uncached do
        ClientOperatingProfile.active_on(date).reorder(nil)
          .joins(:company).merge(live_companies)
          .where("client_operating_profiles.options @> ?", { subdomain_enabled: true }.to_json)
          .pluck("companies.subdomain_slug", "companies.id").to_h
      end
    end
    companies_by_slug[slug]
  end
  private_class_method :enabled_company_id

  def self.live_companies
    Company.active.live_payroll.joins(:organization).merge(Organization.active).where.not(subdomain_slug: nil)
  end
  private_class_method :live_companies
end
