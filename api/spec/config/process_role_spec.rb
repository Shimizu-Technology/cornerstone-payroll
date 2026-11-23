# frozen_string_literal: true

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
    expect(result[:paths]).to all(match(%r{\A(?:/up\(|/api/v1/(?:employee/|kiosk/|auth/|public/tenant_branding\z))}))
    expect(result[:paths]).to include("/api/v1/employee/context(.:format)", "/api/v1/public/tenant_branding")
  end

  it "mounts only the payroll surface and excludes employee requests" do
    result = boot_role("payroll_web", "/api/v1/employee/context")
    expect(result).to include(up: 200, up_queries: [], forbidden: 404)
    expect(result[:paths]).to all(match(%r{\A(?:/up\(|/api/v1/(?:(?:admin|client|auth|form_500s|finance|integrations)/|(?:companies|cable_ticket|notification_settings)\())}))
    expect(result[:paths]).to include("/api/v1/admin/companies(.:format)", "/api/v1/auth/me(.:format)")
  end
end
