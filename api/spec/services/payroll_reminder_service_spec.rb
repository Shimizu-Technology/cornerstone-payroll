# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollReminderService do
  let(:company) { create(:company, name: "Test Corp", pay_frequency: "biweekly") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return("re_test_key")
    allow(ENV).to receive(:[]).with("RESEND_FROM_EMAIL").and_return("payroll@test.com")
    allow(ENV).to receive(:[]).with("MAILER_FROM_EMAIL").and_return(nil)
    allow(ENV).to receive(:fetch).with("FRONTEND_URL").and_return("https://app.test.com")
  end

  describe ".run_all!" do
    context "when no configs are enabled" do
      it "does nothing" do
        create(:payroll_reminder_config, company: company, enabled: false)
        expect(Resend::Emails).not_to receive(:send)
        described_class.run_all!
      end
    end

    context "with an enabled config and upcoming pay period" do
      let!(:config) do
        create(:payroll_reminder_config,
               company: company,
               enabled: true,
               recipients: ["boss@test.com"],
               days_before_due: 3,
               send_overdue_alerts: true)
      end

      let!(:pay_period) do
        create(:pay_period,
               company: company,
               start_date: Date.current - 14,
               end_date: Date.current,
               pay_date: Date.current + 2,
               status: "draft")
      end

      it "sends an upcoming reminder email" do
        expect(Resend::Emails).to receive(:send).with(
          hash_including(to: "boss@test.com", from: "payroll@test.com")
        )
        described_class.run_all!

        log = PayrollReminderLog.where(reminder_type: "upcoming").last
        expect(log).to be_present
        expect(log.reminder_type).to eq("upcoming")
        expect(log.pay_period_id).to eq(pay_period.id)
        expect(log.recipients_snapshot).to eq(["boss@test.com"])
      end

      it "does not send duplicate reminders" do
        expect(Resend::Emails).to receive(:send).once
        described_class.run_all!
        described_class.run_all!
      end

      it "does not send reminders for committed pay periods" do
        pay_period.update!(status: "committed")
        expect(Resend::Emails).not_to receive(:send)
        described_class.run_all!
      end
    end

    context "with an overdue pay period" do
      let!(:config) do
        create(:payroll_reminder_config,
               company: company,
               enabled: true,
               recipients: ["boss@test.com"],
               days_before_due: 3,
               send_overdue_alerts: true)
      end

      let!(:pay_period) do
        create(:pay_period,
               company: company,
               start_date: Date.current - 21,
               end_date: Date.current - 7,
               pay_date: Date.current - 3,
               status: "draft")
      end

      it "sends an overdue alert" do
        expect(Resend::Emails).to receive(:send).with(
          hash_including(to: "boss@test.com")
        )
        described_class.run_all!

        log = PayrollReminderLog.where(reminder_type: "overdue").last
        expect(log.reminder_type).to eq("overdue")
      end

      it "skips overdue alerts when send_overdue_alerts is false" do
        config.update!(send_overdue_alerts: false)
        expect(Resend::Emails).not_to receive(:send)
        described_class.run_all!
      end
    end

    context "create_payroll reminder (no pay period exists yet)" do
      let!(:config) do
        create(:payroll_reminder_config,
               company: company,
               enabled: true,
               recipients: ["boss@test.com"],
               days_before_due: 3,
               send_overdue_alerts: false)
      end

      let!(:last_committed) do
        create(:pay_period,
               company: company,
               start_date: Date.current - 19,
               end_date: Date.current - 6,
               pay_date: Date.current - 1,
               status: "committed")
      end

      it "sends a create_payroll reminder when next period is missing and pay_date approaches" do
        # Biweekly: next period should be (end_date+1) to (end_date+14), pay_date offset = 5 days
        # Expected next: start = current-5, end = current+8, pay_date = current+13
        # With days_before_due=3, trigger = pay_date-3 = current+10, today < that, so no send yet
        # Let's adjust the last period so the next expected pay_date is within the window

        last_committed.update!(
          start_date: Date.current - 28,
          end_date: Date.current - 15,
          pay_date: Date.current - 10,
          status: "committed"
        )
        # Next expected: start=current-14, end=current-1, pay_date=current+4
        # Trigger = current+4 - 3 = current+1 → not yet
        # Adjust further so pay_date is within 3 days:
        last_committed.update!(
          start_date: Date.current - 25,
          end_date: Date.current - 12,
          pay_date: Date.current - 7,
          status: "committed"
        )
        # Next expected: start=current-11, end=current+2, pay_date=current+7
        # Trigger date: current+7-3 = current+4 → still future
        # Let's make it tight:
        last_committed.update!(
          start_date: Date.current - 30,
          end_date: Date.current - 17,
          pay_date: Date.current - 14,
          status: "committed"
        )
        # Next expected: start=current-16, end=current-3, pay_date=current
        # Trigger: current-3 → today >= that ✓
        # No existing period covers current-16..current-3 (only the committed one which ends at current-17)

        expect(Resend::Emails).to receive(:send).with(
          hash_including(to: "boss@test.com")
        )

        described_class.run_all!

        log = PayrollReminderLog.where(reminder_type: "create_payroll").last
        expect(log).to be_present
        expect(log.pay_period_id).to be_nil
        expect(log.expected_pay_date).to eq(Date.current)
      end

      it "does not send create_payroll if the next period already exists" do
        last_committed.update!(
          start_date: Date.current - 30,
          end_date: Date.current - 17,
          pay_date: Date.current - 14,
          status: "committed"
        )

        # Create the expected next period (upcoming reminder may fire, but create_payroll should not)
        create(:pay_period,
               company: company,
               start_date: Date.current - 16,
               end_date: Date.current - 3,
               pay_date: Date.current,
               status: "draft")

        allow(Resend::Emails).to receive(:send)
        described_class.run_all!

        expect(PayrollReminderLog.where(reminder_type: "create_payroll")).to be_empty
      end

      it "does not send duplicate create_payroll reminders" do
        last_committed.update!(
          start_date: Date.current - 30,
          end_date: Date.current - 17,
          pay_date: Date.current - 14,
          status: "committed"
        )

        expect(Resend::Emails).to receive(:send).once
        described_class.run_all!
        described_class.run_all!
      end
    end

    context "when RESEND_API_KEY is missing" do
      before do
        allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return(nil)
      end

      it "skips all reminders" do
        create(:payroll_reminder_config, company: company, enabled: true, recipients: ["boss@test.com"])
        expect(Resend::Emails).not_to receive(:send)
        described_class.run_all!
      end
    end
  end

  describe ".calculate_next_period" do
    it "calculates biweekly correctly" do
      last = build(:pay_period, start_date: Date.new(2026, 3, 23), end_date: Date.new(2026, 4, 5), pay_date: Date.new(2026, 4, 10))
      result = described_class.send(:calculate_next_period, "biweekly", last)
      expect(result[:start_date]).to eq(Date.new(2026, 4, 6))
      expect(result[:end_date]).to eq(Date.new(2026, 4, 19))
      expect(result[:pay_date]).to eq(Date.new(2026, 4, 24))
    end

    it "calculates weekly correctly" do
      last = build(:pay_period, start_date: Date.new(2026, 3, 30), end_date: Date.new(2026, 4, 5), pay_date: Date.new(2026, 4, 7))
      result = described_class.send(:calculate_next_period, "weekly", last)
      expect(result[:start_date]).to eq(Date.new(2026, 4, 6))
      expect(result[:end_date]).to eq(Date.new(2026, 4, 12))
      expect(result[:pay_date]).to eq(Date.new(2026, 4, 14))
    end

    it "calculates semimonthly correctly (first half → second half)" do
      last = build(:pay_period, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 15), pay_date: Date.new(2026, 4, 20))
      result = described_class.send(:calculate_next_period, "semimonthly", last)
      expect(result[:start_date]).to eq(Date.new(2026, 4, 16))
      expect(result[:end_date]).to eq(Date.new(2026, 4, 30))
      expect(result[:pay_date]).to eq(Date.new(2026, 5, 5))
    end

    it "calculates semimonthly correctly (second half → next month first half)" do
      last = build(:pay_period, start_date: Date.new(2026, 4, 16), end_date: Date.new(2026, 4, 30), pay_date: Date.new(2026, 5, 5))
      result = described_class.send(:calculate_next_period, "semimonthly", last)
      expect(result[:start_date]).to eq(Date.new(2026, 5, 1))
      expect(result[:end_date]).to eq(Date.new(2026, 5, 15))
      expect(result[:pay_date]).to eq(Date.new(2026, 5, 20))
    end

    it "calculates monthly correctly" do
      last = build(:pay_period, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 31), pay_date: Date.new(2026, 4, 5))
      result = described_class.send(:calculate_next_period, "monthly", last)
      expect(result[:start_date]).to eq(Date.new(2026, 4, 1))
      expect(result[:end_date]).to eq(Date.new(2026, 4, 30))
      expect(result[:pay_date]).to eq(Date.new(2026, 5, 5))
    end
  end
end
