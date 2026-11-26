# frozen_string_literal: true

class TenantSubdomainRegistry
  # Hosted services always use this domain. Only a local production copy
  # (DEPLOYMENT_ENV=local, see LocalDeployment) serves tenants elsewhere.
  DEFAULT_ROOT_DOMAIN = "shimizu-technology.com"
  SLUG_PATTERN = /\A(?!xn--)[a-z0-9][a-z0-9-]{1,38}[a-z0-9]\z/
  RESERVED_SLUGS = %w[payroll api employee-api clerk clkmail accounts www staging mail admin app my status docs support tax aire aire-api plane shimizu].freeze
  BRANDING_PATH = %r{\A/api/v1/public/tenant_branding/?\z}
  TERMS_PATH = %r{\A/api/v1/public/employee_terms/?\z}
  TERMS_METHODS = %w[GET OPTIONS].freeze
  PORTAL_PATH = %r{\A/api/v1/(?:auth|employee)/}
  BRANDING_METHODS = %w[GET HEAD OPTIONS].freeze
  BRANDING_KEYS = %w[logo_url primary_color accent_color display_name app_name show_main_phone].freeze
  DISPLAY_NAME_MAX = 60
  APP_NAME_MAX = 30
  LOGO_PATH = %r{\A/api/v1/public/tenant_branding/logo/}
  CACHE_TTL = 45.seconds

  PUBLIC_LOGO_HOST = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*\z/i
  PRIVATE_LOGO_HOST = /(?:\A|\.)(?:localhost|local|localdomain|internal|lan|home\.arpa|r2\.cloudflarestorage\.com)\z|(?:\A|\.)s3[^.]*(?:\.[^.]+)*\.amazonaws\.com(?:\.cn)?\z/i

  @cache_version = 0
  CACHE_VERSION_LOCK = Mutex.new

  def self.root_domain
    LocalDeployment.tenant_root_domain || DEFAULT_ROOT_DOMAIN
  end

  def self.tenant_host(slug)
    "#{slug}.#{root_domain}"
  end

  # Browsers include a non-default port in Origin, so a local copy's carries it.
  def self.tenant_origin(slug)
    "https://#{tenant_host(slug)}#{LocalDeployment.port_suffix}"
  end

  def self.host_pattern
    patterns.fetch(:host)
  end

  def self.origin_pattern
    patterns.fetch(:origin)
  end

  def self.client_origin_pattern
    patterns.fetch(:client_origin)
  end

  # Built once per root domain and port; both are fixed for a process.
  def self.patterns
    key = [ root_domain, LocalDeployment.port_suffix ].freeze
    cached = @patterns
    return cached.last if cached&.first == key

    root = Regexp.escape(key.first)
    port = Regexp.escape(key.last)
    built = {
      host: /\A([a-z0-9-]+)\.#{root}\z/,
      origin: /\Ahttps:\/\/([a-z0-9-]+)\.#{root}#{port}\z/,
      client_origin: %r{\Ahttps?://(?:[^/?#@]*@)?([^./?#:]+)\.#{root}\.?(?=[:/?#]|\z)}i
    }.freeze
    @patterns = [ key, built ].freeze
    built
  end
  private_class_method :patterns

  # Recognize malformed variants of tenant origins too, so they cannot fall
  # back to the static allowlist or the pre-cutover Clerk behavior.
  def self.client_origin?(origin)
    return false unless origin.is_a?(String)

    slug = origin.strip.match(client_origin_pattern)&.[](1)
    slug.present? && !RESERVED_SLUGS.include?(slug.downcase)
  end

  def self.tenant_shaped_origin?(origin)
    slug = origin_pattern.match(origin.to_s)&.[](1)
    slug.present? && SLUG_PATTERN.match?(slug) && !RESERVED_SLUGS.include?(slug)
  end

  def self.allowed_origin?(origin)
    enabled_origin_company_id(origin).present?
  end

  def self.enabled_origin_company_id(origin)
    return unless origin.is_a?(String)

    enabled_company_id(origin.match(origin_pattern)&.[](1))
  end

  def self.branding_for(host: nil, slug: nil, logo_base_url: nil)
    slug = host.match(host_pattern)&.[](1) if host.is_a?(String) && slug.nil?
    company_id = enabled_company_id(slug)
    return unless company_id

    company = live_companies.find_by(id: company_id, subdomain_slug: slug)
    return unless company

    branding = company.branding.is_a?(Hash) ? company.branding : {}
    # Only public values: never Help contacts, emails or storage keys. Named
    # Help contacts are served to signed-in employees only.
    {
      name: display_text(branding["display_name"], DISPLAY_NAME_MAX) || company.name,
      app_name: display_text(branding["app_name"], APP_NAME_MAX),
      logo_url: uploaded_logo_url(company, slug, logo_base_url) || https_url(branding["logo_url"]),
      primary_color: hex_color(branding["primary_color"]),
      accent_color: hex_color(branding["accent_color"]),
      main_phone: (company.phone.to_s.strip.presence unless branding["show_main_phone"] == false),
      demo: company.demo?
    }
  end

  # The company whose uploaded logo a public logo request may read, or nil
  # when the subdomain isn't enabled or the fingerprint is stale.
  def self.logo_company_for(slug:, digest:)
    company_id = enabled_company_id(slug)
    return unless company_id && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{16}\z/)

    company = live_companies.find_by(id: company_id, subdomain_slug: slug)
    company if company&.brand_logo_digest == digest
  end

  # A content-addressed URL, so a new upload changes the address and the old
  # one can be cached forever.
  def self.uploaded_logo_url(company, slug, base_url)
    return unless base_url.present? && company.brand_logo_digest

    "#{base_url.delete_suffix('/')}/api/v1/public/tenant_branding/logo/#{slug}/#{company.brand_logo_digest}.#{company.brand_logo_extension}"
  end

  def self.display_text(value, max)
    text = value.to_s.squish if value.is_a?(String)
    text if text.present? && text.length <= max && !text.match?(/[[:cntrl:]<>]/)
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
    value if (PUBLIC_LOGO_HOST.match?(host.to_s) && !PRIVATE_LOGO_HOST.match?(host)) || local_tenant_host?(host)
  rescue URI::InvalidURIError
    nil
  end

  # A local production copy's own hosts, e.g. its shared EMPLOYEE_APP_URL.
  def self.local_tenant_host?(host)
    root = LocalDeployment.tenant_root_domain
    host = host.to_s.downcase
    root.present? && host.present? && (host == root || host.end_with?(".#{root}"))
  end
  private_class_method :local_tenant_host?

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
      TenantScope.as_system(reason: "Load effective public subdomain registry") do
        ClientOperatingProfile.uncached do
          ClientOperatingProfile.active_on(date).reorder(nil)
            .joins(:company).merge(live_companies)
            .where("client_operating_profiles.options @> ?", { subdomain_enabled: true }.to_json)
            .pluck("companies.subdomain_slug", "companies.id").to_h
        end
      end
    end
    companies_by_slug[slug]
  end
  private_class_method :enabled_company_id

  # Live clients and demo companies (which run like one); never a practice copy.
  def self.live_companies
    Company.active.operating.joins(:organization).merge(Organization.active).where.not(subdomain_slug: nil)
  end
  private_class_method :live_companies
end
