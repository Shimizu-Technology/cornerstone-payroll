# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe "Conventional staging mail boundary" do
  around do |example|
    old_env = ENV.to_h
    old_adapter = ActiveJob::Base.queue_adapter
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"}]'
    ENV.delete("STAGING_MAIL_ALLOWLIST")
    ActiveJob::Base.queue_adapter = :inline
    example.run
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
    ENV.replace(old_env)
  end

  before do
    stub_const("MailBoundaryOriginalAdapter", Class.new do
      attr_reader :settings
      def initialize(settings = {})
        @settings = settings
      end
      def deliver!(_message); end
    end)
    stub_const("MailBoundaryMailer", Class.new(ActionMailer::Base) do
      self.delivery_method = MailBoundaryOriginalAdapter
      self.perform_deliveries = true

      def sensitive
        attachments["PRIVATE_FILENAME.txt"] = "PRIVATE_ATTACHMENT"
        headers["X-Private"] = "PRIVATE_HEADER"
        headers["Return-Path"] = "PRIVATE_RETURN@example.test"
        headers["Message-ID"] = "<PRIVATE_MESSAGE_ID@example.test>"
        mail(to: "PRIVATE_TO@example.test", cc: "PRIVATE_CC@example.test", bcc: "PRIVATE_BCC@example.test",
          from: "PRIVATE_FROM@example.test", reply_to: "PRIVATE_REPLY@example.test",
          subject: "PRIVATE_SUBJECT", body: "PRIVATE_BODY")
      end

      def html_only
        mail(to: [ "leon@example.test", "employee@example.test" ], from: "sender@example.test",
          subject: "HTML test", content_type: "text/html", body: '<p>Hello <strong>tester</strong></p><img src="https://remote.example.test/private">')
      end

      def plain_text
        mail(to: "leon@example.test", from: "sender@example.test", subject: "Plain", body: "Hello tester")
      end

      def multipart
        mail(to: "leon@example.test", from: "sender@example.test", subject: "Multipart") do |format|
          format.text { render plain: "Plain alternative" }
          format.html { render html: "<p>HTML alternative</p>".html_safe }
        end
      end
    end)
    allow(Resend::Emails).to receive(:send).and_return({ "id" => "synthetic" })
  end

  [ :deliver_now, :deliver_now!, :deliver_later! ].each do |method|
    [ true, false ].each do |enabled|
      it "contains #{method} with per-mailer perform_deliveries=#{enabled}" do
        MailBoundaryMailer.perform_deliveries = enabled
        expect_any_instance_of(MailBoundaryOriginalAdapter).not_to receive(:deliver!)
        expect(Resend::Emails).not_to receive(:send)
        MailBoundaryMailer.sensitive.public_send(method)
      end
    end
  end

  [ true, false ].each do |enabled|
    it "contains Mail::Message#deliver! after explicit adapter and perform_deliveries=#{enabled} overrides" do
      message = MailBoundaryMailer.sensitive.message
      message.delivery_method(MailBoundaryOriginalAdapter)
      message.perform_deliveries = enabled
      expect(message.delivery_method).not_to receive(:deliver!)
      expect(Resend::Emails).not_to receive(:send)
      message.deliver!
      expect(message.delivery_method).to be_a(StagingActionMailerDelivery)
    end
  end

  it "enforces containment after a later interceptor overrides delivery settings" do
    late_interceptor = Class.new do
      def self.delivering_email(message)
        message.delivery_method(MailBoundaryOriginalAdapter)
        message.perform_deliveries = true
      end
    end
    ActionMailer::Base.register_interceptor(late_interceptor)
    expect_any_instance_of(MailBoundaryOriginalAdapter).not_to receive(:deliver!)
    expect(Resend::Emails).not_to receive(:send)
    MailBoundaryMailer.sensitive.deliver_now!
  ensure
    ActionMailer::Base.unregister_interceptor(late_interceptor)
  end

  it "redacts captured content before notification serialization and debug logging" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    old_logger = ActionMailer::Base.logger
    ActionMailer::Base.logger = logger
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |event|
      payloads << event.payload.deep_dup
    end
    expect(Resend::Emails).not_to receive(:send)
    message = MailBoundaryMailer.sensitive.deliver_now
    expect(payloads.size).to eq(1)
    expect(payloads.first[:mail]).to include("STAGING", "redacted")
    expect(output.string).to include("redacted")
    markers = %w[PRIVATE_TO PRIVATE_CC PRIVATE_BCC PRIVATE_FROM PRIVATE_REPLY PRIVATE_SUBJECT PRIVATE_BODY PRIVATE_ATTACHMENT PRIVATE_FILENAME PRIVATE_HEADER PRIVATE_MESSAGE_ID PRIVATE_RETURN UFJJVkFURV9BVFRBQ0hNRU5U]
    aggregate_failures do
      markers.each do |marker|
        expect(payloads.inspect.downcase).not_to include(marker.downcase)
        expect(output.string.downcase).not_to include(marker.downcase)
        expect(message.encoded.downcase).not_to include(marker.downcase)
      end
      expect(message.attachments).to be_empty
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    ActionMailer::Base.logger = old_logger
  end

  it "passes single-part HTML as HTML to the shared transport for sanitization" do
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    expect(StagingMailTransport).to receive(:deliver).with(hash_including(html: a_string_including("<strong>tester</strong>"))).and_call_original
    expect(Resend::Emails).to receive(:send) do |payload|
      expect(payload[:to]).to eq([ "leon@example.test" ])
      expect(payload[:subject]).to eq("[STAGING] HTML test")
      expect(payload[:text]).to eq("Hello tester")
      expect(payload).not_to have_key(:html)
      { "id" => "synthetic" }
    end
    MailBoundaryMailer.html_only.deliver_now!
  end

  it "preserves plain text and multipart alternatives in the shared transport" do
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    expect(Resend::Emails).to receive(:send).with(hash_including(text: "Hello tester"))
    MailBoundaryMailer.plain_text.deliver_now
    expect(StagingMailTransport).to receive(:deliver).with(hash_including(text: "Plain alternative", html: a_string_including("HTML alternative"))).and_call_original
    expect(Resend::Emails).to receive(:send).with(hash_including(text: "Plain alternative"))
    MailBoundaryMailer.multipart.deliver_now
  end

  %w[production test].each do |deployment|
    it "preserves the original adapter, headers and content in #{deployment}" do
      ENV["DEPLOYMENT_ENV"] = deployment
      message = MailBoundaryMailer.sensitive.message
      original = message.delivery_method
      expect(original).to receive(:deliver!).with(message)
      expect(Resend::Emails).not_to receive(:send)
      message.deliver!
      expect(message.delivery_method).to equal(original)
      expect(message.subject).to eq("PRIVATE_SUBJECT")
      expect(message["X-Private"].value).to eq("PRIVATE_HEADER")
      expect(message.attachments.first.decoded).to eq("PRIVATE_ATTACHMENT")
    end
  end
end
