require "rails_helper"

RSpec.describe "Cable request log filtering" do
  it "redacts the native ticket without changing the request used for authentication" do
    environment = Rails.application.env_config.merge(
      Rack::MockRequest.env_for("/cable?ticket=synthetic-cable-ticket&client_hint=2")
    )
    request = ActionDispatch::Request.new(environment)

    expect(request.filtered_path).to include("ticket=[FILTERED]", "client_hint=2")
    expect(request.filtered_path).not_to include("synthetic-cable-ticket")
    expect(request.query_parameters["ticket"]).to eq("synthetic-cable-ticket")
  end
end
