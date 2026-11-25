# frozen_string_literal: true

require "rails_helper"
require "open3"
require "json"

RSpec.describe "APP_PROCESS_ROLE" do
  def boot_role(role, forbidden_path)
    code = <<~RUBY_CODE
      session = ActionDispatch::Integration::Session.new(Rails.application)
      queries = []
      capture = ->(*args) { queries << args.last[:name] }
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { session.get("/up") }
      puts JSON.generate(
        up: session.response.status,
        up_queries: queries,
        forbidden: session.get(#{forbidden_path.inspect}),
        cable_mount_path: Rails.application.config.action_cable.mount_path,
        paths: Rails.application.routes.routes.map { |route| route.path.spec.to_s }
      )
    RUBY_CODE
    output, error, status = Open3.capture3(
      { "APP_PROCESS_ROLE" => role, "RAILS_ENV" => "test", "TEST_DATABASE_URL" => "postgres://127.0.0.1:1/no_db" },
      "bundle", "exec", "rails", "runner", code, chdir: File.expand_path("../..", __dir__)
    )
    expect(status.success?).to eq(true), error
    JSON.parse(output.lines.last, symbolize_names: true)
  end

  it "mounts only the employee surface and serves /up without SQL" do
    result = boot_role("employee_web", "/api/v1/admin/companies")
    expect(result).to include(up: 200, up_queries: [], forbidden: 404)
    expect(result[:cable_mount_path]).to be_nil
    expect(result[:paths]).to all(match(%r{\A(?:(?:/up|/health/dependencies)\(|/api/v1/(?:employee/|kiosk/|auth/|public/employee_terms\z|public/tenant_branding(?:\z|/logo/)))}))
    expect(result[:paths]).to include("/api/v1/employee/context(.:format)", "/api/v1/public/employee_terms", "/api/v1/public/tenant_branding",
      "/api/v1/public/tenant_branding/logo/:slug/:file", "/health/dependencies(.:format)")
    expect(result[:paths]).to all(match(ProcessRole::EMPLOYEE_WEB_ROUTE_PATTERN))
  end

  it "keeps the employee route allowlist closed to payroll paths" do
    %w[/cable /api/v1/admin/companies(.:format) /api/v1/client/employees(.:format) /api/v1/finance/overview(.:format)
       /api/v1/integrations/aire/x /rails/active_storage/blobs /api/v1/employee /api/v1/employeex/y
       /api/v1/public/tenant_branding/logo /api/v1/public/tenant_branding/other].each do |path|
      expect(ProcessRole::EMPLOYEE_WEB_ROUTE_PATTERN).not_to match(path)
    end
  end

  it "mounts only the payroll surface and excludes employee requests" do
    result = boot_role("payroll_web", "/api/v1/employee/context")
    expect(result).to include(up: 200, up_queries: [], forbidden: 404)
    expect(result[:cable_mount_path]).to eq("/cable")
    expect(result[:paths]).to all(match(%r{\A(?:/cable\z|(?:/up|/health/dependencies)\(|/api/v1/(?:(?:admin|client|auth|form_500s|finance|integrations)/|(?:companies|cable_ticket|notification_settings)\(|public/tenant_branding(?:\z|/logo/)))}))
    expect(result[:paths]).to include("/cable", "/health/dependencies(.:format)", "/api/v1/public/tenant_branding",
      "/api/v1/admin/companies(.:format)", "/api/v1/auth/me(.:format)")
  end

  it "passes the employee_web readiness checks with their real probes in a booted employee process" do
    code = <<~RUBY_CODE
      env = { "APP_PROCESS_ROLE" => "employee_web", "DB_POOL_MAX" => "3",
              "RACK_ATTACK_REDIS_URL" => "redis://127.0.0.1:6399", "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.com" }
      readiness = ProductionReadiness.new(env: env, time_sources: -> { [] }, tax_year_readiness: -> { { warnings: [] } })
      puts JSON.generate(readiness.run(live: false).checks.select { |check| check.name.start_with?("employee_web:") }.to_h { |check| [ check.name, check.passed ] })
    RUBY_CODE
    output, error, status = Open3.capture3(
      { "APP_PROCESS_ROLE" => "employee_web", "DB_POOL_MAX" => "3", "RACK_ATTACK_REDIS_URL" => "redis://127.0.0.1:6399",
        "RAILS_ENV" => "test" },
      "bundle", "exec", "rails", "runner", code, chdir: File.expand_path("../..", __dir__)
    )
    expect(status.success?).to eq(true), error
    results = JSON.parse(output.lines.last)
    expect(results.length).to eq(4)
    expect(results).to all(satisfy { |_name, passed| passed })
  end
end
