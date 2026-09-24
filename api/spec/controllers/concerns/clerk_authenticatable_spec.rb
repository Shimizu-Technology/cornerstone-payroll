# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClerkAuthenticatable do
  let(:controller_class) do
    Class.new(ActionController::API) do
      include ClerkAuthenticatable

      public :fetch_jwks
    end
  end

  it "reads JWKS from the request-path cache without caching failed lookups" do
    request_store = instance_double(ActiveSupport::Cache::Store)
    allow(RequestPathCache).to receive(:store).and_return(request_store)
    allow(request_store).to receive(:fetch)
      .with("clerk_jwks", expires_in: 1.hour, skip_nil: true)
      .and_return([])
    expect(Rails).not_to receive(:cache)

    expect(controller_class.new.fetch_jwks).to eq([])
  end
end
