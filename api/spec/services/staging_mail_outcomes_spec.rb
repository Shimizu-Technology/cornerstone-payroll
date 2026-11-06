# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe "Staging mail outcomes" do
  around do |example|
    old_env = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"}]'
    ENV["RESEND_FROM_EMAIL"] = "sender@example.test"
    ENV.delete("RESEND_API_KEY")
    ENV.delete("STAGING_MAIL_ALLOWLIST")
    @output = StringIO.new
    old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@output)
    example.run
  ensure
    Rails.logger = old_logger
    ENV.replace(old_env)
  end

  let(:user) { create(:user, email: "PRIVATE_RECIPIENT@example.test") }
  let(:company) { user.company }
  let(:config) { create(:payroll_reminder_config, company: company, enabled: true, recipients: [ user.email ]) }
  let(:period) { create(:pay_period, company: company, start_date: Date.current - 14, end_date: Date.current, pay_date: Date.current + 2) }

  it "returns a distinct invite capture outcome with redacted evidence" do
    expect(Resend::Emails).not_to receive(:send)
    expect(UserInviteEmailService.send_invite(user: user, invited_by: nil)).to eq(:captured)
    expect(@output.string).to include("captured", "user_id=#{user.id}")
    expect(@output.string).not_to include(user.email, "Sent invite")
  end

  it "completes a captured invite job without claiming delivery or retrying" do
    expect(Resend::Emails).not_to receive(:send)
    expect(SendUserInviteEmailJob.perform_now(user.id)).to eq(:captured)
    expect(@output.string).to include("captured", "user_id=#{user.id}")
    expect(@output.string).not_to include(user.email)
  end

  it "logs invite failures with IDs and class but no message or recipient" do
    allow(StagingMailTransport).to receive(:deliver).and_raise(RuntimeError, "PRIVATE_ERROR #{user.email}")
    expect(UserInviteEmailService.send_invite(user: user, invited_by: nil)).to be(false)
    expect(@output.string).to include("RuntimeError", "user_id=#{user.id}")
    expect(@output.string).not_to include("PRIVATE_ERROR", user.email)
  end

  it "keeps a failed invite job exception free of recipient details" do
    allow(UserInviteEmailService).to receive(:send_invite).and_return(false)
    expect { SendUserInviteEmailJob.new.perform(user.id) }.to raise_error(RuntimeError, "Failed to send invite email for user_id=#{user.id}")
  end

  it "runs the daily reminder job in shared mode with capture and no provider send" do
    ENV["STAGING_SHARES_PRODUCTION_CLERK"] = "true"
    ENV["STAGING_SHARES_PRODUCTION_STORAGE"] = "true"
    ENV["STAGING_STORAGE_WRITE_PREFIX"] = "staging/2026-10-25/"
    config
    company.update!(payroll_environment: "live")
    period
    expect(Resend::Emails).not_to receive(:send)
    SendPayrollRemindersJob.perform_now
    expect(PayrollReminderLog.where(company: company)).to be_empty
    expect(@output.string).to include("captured", "company=#{company.id}")
  end

  it "records captured period reminders without a false sent log" do
    expect(Resend::Emails).not_to receive(:send)
    PayrollReminderService.send(:send_period_reminder, config, period, "upcoming")
    expect(PayrollReminderLog.where(company: company)).to be_empty
    expect(@output.string).to include("captured", "company=#{company.id}", "pay_period=#{period.id}")
    expect(@output.string).not_to include(user.email, "Sent upcoming")
  end

  it "records captured create reminders without a false sent log" do
    expect(Resend::Emails).not_to receive(:send)
    expected = { start_date: Date.current, end_date: Date.current + 13, pay_date: Date.current + 14 }
    PayrollReminderService.send(:send_create_reminder, config, company, expected)
    expect(PayrollReminderLog.where(company: company)).to be_empty
    expect(@output.string).to include("captured", "company=#{company.id}")
    expect(@output.string).not_to include(user.email, "Sent create_payroll")
  end

  it "records only recipients actually sent to for a mixed staging reminder" do
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test"
    config.update!(recipients: [ "leon@example.test", user.email ])
    expect(Resend::Emails).to receive(:send).once.with(hash_including(to: [ "leon@example.test" ])).and_return({ "id" => "synthetic" })
    PayrollReminderService.send(:send_period_reminder, config, period, "upcoming")
    expect(PayrollReminderLog.last.recipients_snapshot).to eq([ "leon@example.test" ])
    expect(@output.string).to include("captured=1", "sent=1")
    expect(@output.string).not_to include(user.email)
  end

  it "retains redacted reminder error evidence and removes the failed send lock" do
    allow(StagingMailTransport).to receive(:deliver).and_raise(RuntimeError, "PRIVATE_ERROR #{user.email}")
    PayrollReminderService.send(:send_period_reminder, config, period, "upcoming")
    expect(PayrollReminderLog.where(company: company)).to be_empty
    expect(@output.string).to include("RuntimeError", "company=#{company.id}", "pay_period=#{period.id}")
    expect(@output.string).not_to include("PRIVATE_ERROR", user.email)
  end

  it "preserves successful delivery evidence when another staging recipient fails" do
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"},{"user_id":2,"email":"other@example.test","clerk_subject":"user_other"}]'
    ENV["STAGING_MAIL_ALLOWLIST"] = "leon@example.test,other@example.test"
    config.update!(recipients: [ "leon@example.test", "other@example.test", user.email ])
    expect(Resend::Emails).to receive(:send).with(hash_including(to: [ "leon@example.test" ])).and_return({ "id" => "synthetic" })
    expect(Resend::Emails).to receive(:send).with(hash_including(to: [ "other@example.test" ])).and_raise(RuntimeError, "PRIVATE_ERROR")
    PayrollReminderService.send(:send_period_reminder, config, period, "upcoming")
    expect(PayrollReminderLog.last&.recipients_snapshot).to eq([ "leon@example.test" ])
    expect(@output.string).to include("RuntimeError", "company=#{company.id}", "pay_period=#{period.id}", "captured=1", "sent=1", "failed=1")
    expect(@output.string).not_to include("PRIVATE_ERROR", user.email, "other@example.test")
  end

  it "retains class and company evidence when scheduling a company fails" do
    config
    allow(PayrollReminderService).to receive(:process_company).and_raise(RuntimeError, "PRIVATE_ERROR")
    PayrollReminderService.run_all!
    expect(@output.string).to include("RuntimeError", "company #{company.id}")
    expect(@output.string).not_to include("PRIVATE_ERROR")
  end

  it "retains class and company evidence when a create reminder fails" do
    allow(StagingMailTransport).to receive(:deliver).and_raise(RuntimeError, "PRIVATE_ERROR")
    expected = { start_date: Date.current, end_date: Date.current + 13, pay_date: Date.current + 14 }
    PayrollReminderService.send(:send_create_reminder, config, company, expected)
    expect(PayrollReminderLog.where(company: company)).to be_empty
    expect(@output.string).to include("RuntimeError", "company=#{company.id}")
    expect(@output.string).not_to include("PRIVATE_ERROR", user.email)
  end

  %w[production test].each do |deployment|
    it "preserves invite send outcomes in #{deployment}" do
      ENV["DEPLOYMENT_ENV"] = deployment
      ENV["RESEND_API_KEY"] = "synthetic"
      expect(Resend::Emails).to receive(:send).with(hash_including(to: user.email, html: a_string_including("Invitation"))).and_return({ "id" => "synthetic" })
      expect(UserInviteEmailService.send_invite(user: user, invited_by: nil)).to be(true)
    end
  end
end
