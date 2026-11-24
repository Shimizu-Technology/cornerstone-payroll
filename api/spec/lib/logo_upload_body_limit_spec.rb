# frozen_string_literal: true

require "rails_helper"

RSpec.describe LogoUploadBodyLimit do
  let(:app) { ->(_env) { [ 200, {}, [ "passed" ] ] } }
  let(:middleware) { described_class.new(app) }

  def call(path, method: "POST", length: "100", chunked: false)
    env = Rack::MockRequest.env_for("/", method: method)
    env["PATH_INFO"] = path
    if length.nil?
      env.delete("CONTENT_LENGTH")
    else
      env["CONTENT_LENGTH"] = length
    end
    env["HTTP_TRANSFER_ENCODING"] = "chunked" if chunked
    status, headers, body = middleware.call(env)
    [ status, headers, body.each.to_a.join ]
  end

  it "limits only POSTs to the two logo upload routes" do
    %w[/api/v1/admin/employee_app_settings/logo /api/v1/client/employee_app_settings/logo //api/v1/client/employee_app_settings/logo/].each do |path|
      expect(call(path, length: "2000000").first).to eq(413)
      expect(call(path, length: "1000000").first).to eq(200)
    end
    expect(call("/api/v1/client/documents", length: "50000000").first).to eq(200)
    expect(call("/api/v1/admin/invoice_billing_profiles/1/logo", length: "50000000").first).to eq(200)
    expect(call("/api/v1/client/employee_app_settings/logo", method: "GET", length: nil).first).to eq(200)
  end

  it "refuses an upload with no length, a chunked body or a malformed length" do
    path = "/api/v1/client/employee_app_settings/logo"
    status, headers, body = call(path, length: nil)
    expect(status).to eq(411)
    expect(headers["content-type"]).to eq("application/json")
    expect(JSON.parse(body)["error"]).to include("didn't say how large")
    expect(call(path, chunked: true).first).to eq(411)
    expect(call(path, length: "12abc").first).to eq(413)
  end
end
