# frozen_string_literal: true

require "uri"
require "ipaddr"
require "socket"

# Reject libpq routing indirection before opening a socket, then verify the
# selected live peer and backend with read-only information before any writes.
class StagingDatabasePolicy
  ROUTING_ENV = %w[PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGSERVICEFILE PGSYSCONFDIR PGOPTIONS PGTARGETSESSIONATTRS PGLOADBALANCEHOSTS].freeze
  ROUTING_PARAMETERS = %w[hostaddr service servicefile options target_session_attrs load_balance_hosts replication].freeze
  URL_OPTIONS = %w[sslmode sslrootcert sslcert sslkey sslpassword ssl_min_protocol_version ssl_max_protocol_version channel_binding connect_timeout application_name keepalives keepalives_idle keepalives_interval keepalives_count tcp_user_timeout gssencmode].freeze

  class << self
    def validate_config!(env: ENV)
      fail!("Clone containment requires DEPLOYMENT_ENV=staging") unless env["DEPLOYMENT_ENV"] == "staging"
      ROUTING_ENV.each { |name| fail!("Remove #{name}: staging database routing overrides are forbidden") unless env[name].to_s.empty? }
      allowed, denied = host_lists!(env)
      StagingOutboundPolicy.require_setting!("DATABASE_URL", env)
      urls = StagingOutboundPolicy::DATABASE_SETTINGS.filter_map do |name|
        next if env[name].to_s.empty?
        [ name, parse_url!(env[name], name, allowed, denied) ]
      end.to_h
      primary = urls.fetch("DATABASE_URL")
      %w[QUEUE_DATABASE_URL CACHE_DATABASE_URL CABLE_DATABASE_URL].each do |name|
        next unless urls[name]
        fail!("Separate #{name} is unsupported by staging clone containment") unless identity(urls[name]) == identity(primary)
      end
      true
    end

    def validate_parameters!(parameters, env: ENV)
      return true unless env["DEPLOYMENT_ENV"] == "staging"
      validate_config!(env: env)
      values = parameters.stringify_keys
      ROUTING_PARAMETERS.each { |name| fail!("Staging database routing parameter #{name} is forbidden") unless values[name].to_s.empty? }
      allowed, denied = host_lists!(env)
      host = single_host!(values["host"])
      fail!("Actual database connection settings failed STAGING_DATABASE_HOSTS assertion") unless allowed.include?(host) && !denied.include?(host)
      database = values["dbname"] || values["database"]
      fail!("Ambiguous staging database name") unless database.to_s.match?(/\A[A-Za-z0-9_.-]+\z/)
      port = values["port"] || 5432
      fail!("Ambiguous staging database port") unless port.to_s.match?(/\A\d+\z/) && (1..65_535).cover?(port.to_i)
      primary = URI.parse(env.fetch("DATABASE_URL"))
      unless [ host.sub("-pooler.", "."), port.to_i, "/#{database}" ] == identity(primary)
        fail!("Resolved staging database role does not match the primary clone identity")
      end
      true
    end

    def validate_rails!(env: ENV)
      return true unless env["DEPLOYMENT_ENV"] == "staging"
      ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |config|
        validate_parameters!(config.configuration_hash, env: env)
      end
      true
    end

    def validate_live!(raw, env: ENV)
      return true unless env["DEPLOYMENT_ENV"] == "staging"
      validate_config!(env: env)
      allowed, denied = host_lists!(env)
      host = single_host!(raw.host)
      fail!("Actual database connection failed STAGING_DATABASE_HOSTS assertion") unless allowed.include?(host) && !denied.include?(host)
      peer = ip!(raw.hostaddr)
      denied_addresses = denied.filter_map { |value| IPAddr.new(value).to_s rescue nil }
      fail!("Actual database peer is denied") if denied_addresses.include?(peer)
      addresses = Addrinfo.getaddrinfo(host, nil, :UNSPEC, :STREAM).map { |address| ip!(address.ip_address) }.uniq
      fail!("Actual database peer did not match the approved host resolution") unless addresses.include?(peer)
      backend = raw.exec("SELECT host(inet_server_addr()) AS address, inet_server_port() AS port, current_database() AS database").first
      address = ip!(backend&.fetch("address", nil))
      fail!("Actual database backend is denied") if denied_addresses.include?(address)
      expected = URI.decode_www_form_component(URI.parse(env.fetch("DATABASE_URL")).path.delete_prefix("/"))
      unless backend["database"] == raw.db && raw.db == expected && backend["port"].to_s.match?(/\A\d+\z/) && raw.port.to_s.match?(/\A\d+\z/)
        fail!("Actual database backend identity is ambiguous")
      end
      true
    rescue SocketError, IPAddr::InvalidAddressError, NoMethodError, KeyError, PG::Error
      fail!("Could not verify the actual staging database connection")
    end

    private

    def host_lists!(env)
      allowed = StagingOutboundPolicy.list("STAGING_DATABASE_HOSTS", env)
      denied = StagingOutboundPolicy.list("PRODUCTION_DATABASE_HOSTS", env)
      fail!("Staging requires STAGING_DATABASE_HOSTS and PRODUCTION_DATABASE_HOSTS") if allowed.empty? || denied.empty? || !(allowed & denied).empty?
      (allowed + denied).each { |host| single_host!(host) }
      [ allowed, denied ]
    end

    def parse_url!(value, name, allowed, denied)
      uri = URI.parse(value)
      host = single_host!(uri.hostname)
      unless %w[postgres postgresql].include?(uri.scheme) && allowed.include?(host) && !denied.include?(host) && uri.fragment.nil? && uri.path.match?(%r{\A/[A-Za-z0-9_.-]+\z})
        fail!("Unsafe #{name}: staging database host assertion failed")
      end
      options = URI.decode_www_form(uri.query.to_s)
      keys = options.map(&:first)
      unless keys.uniq == keys && (keys - URL_OPTIONS).empty?
        fail!("Unsafe #{name}: staging database routing overrides are forbidden")
      end
      uri
    rescue URI::InvalidURIError, ArgumentError
      fail!("Invalid staging database URL")
    end

    def identity(uri)
      [ uri.hostname.to_s.downcase.sub("-pooler.", "."), uri.port || 5432, uri.path ]
    end

    def single_host!(value)
      host = value.to_s.downcase
      valid = host.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/) || (host.include?(":") && (IPAddr.new(host).ipv6? rescue false))
      fail!("Ambiguous staging database routing host") unless valid
      host
    end

    def ip!(value)
      fail!("Actual staging database address is missing") if value.to_s.empty?
      IPAddr.new(value.to_s).to_s
    end

    def fail!(message)
      raise StagingOutboundPolicy::ConfigurationError, message
    end
  end
end
