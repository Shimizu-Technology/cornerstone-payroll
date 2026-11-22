# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClerkAuthenticatable do
  let(:controller_class) do
    Class.new(ActionController::API) do
      include ClerkAuthenticatable

      public :verify_clerk_token
    end
  end

  it "delegates token verification exclusively to ClerkTokenVerifier" do
    verifier = instance_double(ClerkTokenVerifier)
    allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
    allow(verifier).to receive(:verify).with("signed.jwt.token").and_return({ "sub" => "user_123" })

    controller = controller_class.new
    expect(controller.verify_clerk_token("signed.jwt.token")).to eq({ "sub" => "user_123" })
    expect(controller.respond_to?(:fetch_jwks, true)).to be(false)
    expect(controller.respond_to?(:clerk_issuer, true)).to be(false)
  end
end
