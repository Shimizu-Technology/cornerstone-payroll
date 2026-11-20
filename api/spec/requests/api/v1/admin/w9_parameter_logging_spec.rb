# frozen_string_literal: true

require "rails_helper"

# The W-9 form ("add as a new contractor") posts the payee's full TIN. It must
# never reach the request log, whether the request succeeds or fails.
RSpec.describe "W-9 request log filtering", type: :request do
  let!(:company) { create(:company, ein: "98-7654321") }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:tin) { "345-67-7890" }

  before do
    allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_user) { admin }
    allow_any_instance_of(Api::V1::Admin::YearEndController).to receive(:current_company_id) { company.id }
  end

  # Runs the request with the controller log captured, and returns the log
  # text and the params ActionController reported.
  def logged_request
    output = StringIO.new
    original = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(output).tap { |logger| logger.level = :debug }
    reported = []
    callback = ->(*, payload) { reported << payload[:params] }
    ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") { yield }
    [ output.string, reported.sole ]
  ensure
    ActionController::Base.logger = original
  end

  def post_w9(contractor)
    post "/api/v1/admin/year_end/one_off_payees/contractor", params: {
      payee: { tax_year: 2026, code: "one_off_payee:non_employee_check:999999", digest: "stale", contractor: contractor }
    }
  end

  it "filters the nested TIN and contractor EIN on a failed request" do
    log, params = logged_request do
      post_w9(contractor_type: "individual", first_name: "Ana", last_name: "Cruz", tin: tin, contractor_ein: "12-3456789",
              address_line1: "7 Route 8", city: "Maite", state: "GU", zip: "96910", w9_on_file: true)
    end

    expect(response.status).to be >= 400
    expect(params.dig("payee", "contractor", "tin")).to eq("[FILTERED]")
    expect(params.dig("payee", "contractor", "contractor_ein")).to eq("[FILTERED]")
    expect(params.dig("payee", "contractor", "first_name")).to eq("Ana")
    expect(log).to include("Parameters:", "[FILTERED]")
    expect(log).not_to include(tin, tin.delete("-"), "12-3456789", "123456789")
  end

  it "filters the TIN whatever its format, and leaves similar names alone" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter("payee" => { "contractor" => { "tin" => "345677890", "TIN" => "345677890" } }, "settings" => { "x" => 1 }, "routine" => "a")

    expect(filtered.dig("payee", "contractor")).to eq("tin" => "[FILTERED]", "TIN" => "[FILTERED]")
    expect(filtered).to include("settings" => { "x" => 1 }, "routine" => "a")
  end
end
