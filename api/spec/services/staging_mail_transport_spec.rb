# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingMailTransport do
  around do |example|
    old = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"}]'
    ENV.delete("STAGING_MAIL_ALLOWLIST")
    example.run
  ensure
    ENV.replace(old)
  end

  it "captures without provider calls or sensitive log content" do
    expect(Resend::Emails).not_to receive(:send)
    expect(Rails.logger).to receive(:info).with("[STAGING] captured email; recipient/body/subject/attachments redacted")
    expect(described_class.deliver(to: "employee@example.test", subject: "Private payroll", text: "SSN data")).to include("staging_captured" => true)
  end

  it "sends an allowlisted test message through the sole transport" do
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    expect(Resend::Emails).to receive(:send).with(hash_including(to: [ "leon@example.test" ], subject: "[STAGING] Test")).and_return({ "id" => "synthetic-id" })
    described_class.deliver(to: [ "leon@example.test", "employee@example.test" ], cc: [ "employee@example.test" ], subject: "Test", attachments: [ { content: "private" } ])
  end

  it "suppresses conventional Action Mailer delivery" do
    mail = Mail.new { to "employee@example.test"; from "sender@example.test"; subject "Private"; body "Private" }
    StagingMailInterceptor.delivering_email(mail)
    expect(mail.perform_deliveries).to eq(false)
  end

  it "filters and routes conventional allowlisted mail through the shared transport" do
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    mail = Mail.new { to [ "leon@example.test", "employee@example.test" ]; from "sender@example.test"; subject "Test"; body "Sample" }
    mail.cc = "employee@example.test"
    mail.add_file(filename: "private.txt", content: "private")
    StagingMailInterceptor.delivering_email(mail)
    expect(mail.to).to eq([ "leon@example.test" ])
    expect(mail.cc).to be_nil
    expect(mail.attachments).to be_empty
    expect(mail.subject).to eq("[STAGING] Test")
    expect(StagingMailTransport).to receive(:deliver).with(hash_including(to: [ "leon@example.test" ]))
    mail.delivery_method.deliver!(mail)
  end

  it "preserves production and ordinary test payloads and provider responses" do
    %w[production test].each do |deployment|
      ENV["DEPLOYMENT_ENV"] = deployment
      payload = { to: "employee@example.test", subject: "Normal", attachments: [ { content: "original" } ] }
      expect(Resend::Emails).to receive(:send).with(payload).and_return({ "id" => "original" })
      expect(described_class.deliver(payload)).to eq({ "id" => "original" })
    end
  end
end
