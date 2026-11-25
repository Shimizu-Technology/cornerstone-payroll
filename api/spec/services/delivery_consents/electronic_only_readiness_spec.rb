# frozen_string_literal: true

require "rails_helper"

RSpec.describe DeliveryConsents::ElectronicOnlyReadiness do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:user) { create(:user, company: company, role: "portal_employee") }
  let(:link) { EmployeeAccountLink.create!(company: company, employee: employee, user: user, status: "active") }

  before do
    DeliveryDisclosures::DraftSeeds.seed!
  end

  describe ".evaluate" do
    it "blocks electronic-only delivery by default during the pilot for both kinds" do
      DeliveryDisclosure::KINDS.each do |kind|
        result = described_class.evaluate(kind: kind)
        expect(result.ready?).to be(false)
        expect(result.paper_required?).to be(true)
        expect(result.blockers.map(&:key)).to contain_exactly(
          :disclosure_approved,
          :drt_answered,
          :bounce_tracking_exists,
          :paper_on_withdrawal_verified
        )
      end
    end

    it "stays not ready when any single gate is missing" do
      approved = DeliveryDisclosure.create!(
        kind: "w2gu",
        version: "2027-01-01-approved-1",
        title: "Approved W-2GU Consent",
        text: "Counsel-approved W-2GU disclosure text.",
        status: "approved",
        published_at: Time.current
      )

      [
        { disclosure: DeliveryDisclosure.draft.for_kind("w2gu").first, drt_answered: true, bounce_tracking_exists: true, paper_on_withdrawal_verified: true, missing: :disclosure_approved },
        { disclosure: approved, drt_answered: false, bounce_tracking_exists: true, paper_on_withdrawal_verified: true, missing: :drt_answered },
        { disclosure: approved, drt_answered: true, bounce_tracking_exists: false, paper_on_withdrawal_verified: true, missing: :bounce_tracking_exists },
        { disclosure: approved, drt_answered: true, bounce_tracking_exists: true, paper_on_withdrawal_verified: false, missing: :paper_on_withdrawal_verified }
      ].each do |scenario|
        missing = scenario.delete(:missing)
        result = described_class.evaluate(kind: "w2gu", **scenario)
        expect(result.ready?).to be(false), "expected readiness to fail when #{missing} is unmet"
        expect(result.blockers.map(&:key)).to eq([ missing ])
      end
    end

    it "becomes ready only when all four gates pass" do
      approved = DeliveryDisclosure.create!(
        kind: "w2gu",
        version: "2027-01-01-approved-1",
        title: "Approved W-2GU Consent",
        text: "Counsel-approved W-2GU disclosure text.",
        status: "approved",
        published_at: Time.current
      )

      result = described_class.evaluate(
        kind: "w2gu",
        disclosure: approved,
        drt_answered: true,
        bounce_tracking_exists: true,
        paper_on_withdrawal_verified: true
      )
      expect(result.ready?).to be(true)
      expect(result.paper_required?).to be(false)
      expect(result.blockers).to be_empty
    end
  end

  describe ".paper_delivery_required?" do
    it "keeps paper delivery required even after an employee consents during the pilot" do
      draft = DeliveryDisclosure.current_for("pay_statements")
      DeliveryConsent.create!(
        company: company, user: user, employee: employee, employee_account_link: link,
        delivery_disclosure: draft, kind: "pay_statements",
        disclosure_version: draft.version, disclosure_digest: draft.digest,
        given_at: Time.current, method: "employee_portal_checkbox"
      )

      expect(described_class.paper_delivery_required?(company: company, employee: employee, kind: "pay_statements")).to be(true)
    end

    it "still requires paper if consent was given on an older draft or withdrawn, even when all four gates pass" do
      draft = DeliveryDisclosure.current_for("pay_statements")
      approved = DeliveryDisclosure.create!(
        kind: "pay_statements",
        version: "2027-01-01-approved-1",
        title: "Approved Pay Statement Consent",
        text: "Counsel-approved pay statement disclosure text.",
        status: "approved",
        published_at: Time.current
      )

      draft_consent = DeliveryConsent.create!(
        company: company, user: user, employee: employee, employee_account_link: link,
        delivery_disclosure: draft, kind: "pay_statements",
        disclosure_version: draft.version, disclosure_digest: draft.digest,
        given_at: 1.day.ago, method: "employee_portal_checkbox"
      )

      gates = {
        disclosure: approved,
        drt_answered: true,
        bounce_tracking_exists: true,
        paper_on_withdrawal_verified: true
      }

      # Active consent on draft does not satisfy approved disclosure.
      expect(described_class.paper_delivery_required?(company: company, employee: employee, kind: "pay_statements", **gates)).to be(true)

      # Replace with active consent on approved disclosure.
      draft_consent.update!(withdrawn_at: Time.current)
      approved_consent = DeliveryConsent.create!(
        company: company, user: user, employee: employee, employee_account_link: link,
        delivery_disclosure: approved, kind: "pay_statements",
        disclosure_version: approved.version, disclosure_digest: approved.digest,
        given_at: Time.current, method: "employee_portal_checkbox"
      )
      expect(described_class.paper_delivery_required?(company: company, employee: employee, kind: "pay_statements", **gates)).to be(false)

      # Withdrawing immediately requires paper again.
      approved_consent.update!(withdrawn_at: Time.current)
      expect(described_class.paper_delivery_required?(company: company, employee: employee, kind: "pay_statements", **gates)).to be(true)
    end
  end
end
