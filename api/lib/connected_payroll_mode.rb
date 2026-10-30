# frozen_string_literal: true

# Independent of per-company payroll mode and staging network containment.
class ConnectedPayrollMode
  MESSAGE = "Connected payroll is paused"
  class Paused < StandardError; end
  class ConfigurationError < StandardError; end

  def self.mode(env: ENV, environment: Rails.env)
    value = env["CONNECTED_PAYROLL_MODE"]
    return value if %w[enabled paused].include?(value)

    deployment = env["DEPLOYMENT_ENV"].presence || environment.to_s
    return "enabled" if value.nil? && %w[development test].include?(deployment)

    "paused"
  end

  def self.enabled?(**options)
    mode(**options) == "enabled"
  end

  def self.require_enabled!
    raise Paused, MESSAGE unless enabled?
  end

  def self.validate!(env: ENV)
    if env["DEPLOYMENT_ENV"] == "staging" && !%w[enabled paused].include?(env["CONNECTED_PAYROLL_MODE"])
      raise ConfigurationError, "Staging requires CONNECTED_PAYROLL_MODE=enabled or paused"
    end
    true
  end

  def self.capability(**options)
    active = enabled?(**options)
    { mode: mode(**options), enabled: active, message: active ? nil : MESSAGE }
  end
end
