# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261126000200_allow_delivery_consent_in_changes_to_confirm")
require Rails.root.join("db/migrate/20261126000300_seed_draft_delivery_disclosures")

RSpec.describe DeliveryDisclosure do
  PINNED_DIGESTS = {
    "pay_statements" => "2b9953902def45cccc5722527bd5a43902b0501256aafd566eaa3a655110d533",
    "w2gu" => "0b5304525f6585def92c9d805c1df26220887e4437333074563642291cc9fc69"
  }.freeze

  before do
    DeliveryDisclosures::DraftSeeds.seed!
  end

  describe "immutability" do
    it "marks persisted disclosures as readonly and blocks model updates" do
      disclosure = described_class.current_for("pay_statements")
      expect(disclosure).to be_readonly

      expect { disclosure.update!(status: "approved") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      tampered = "Tampered text"
      expect { disclosure.update!(text: tampered, digest: described_class.digest_for(tampered)) }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "blocks direct SQL updates of kind, version, title, text, digest, status, and published_at via database trigger" do
      disclosure = described_class.current_for("w2gu")

      [
        { kind: "pay_statements" },
        { version: "2026-11-25-draft-99" },
        { title: "Altered Title" },
        { text: "Altered disclosure text" },
        { digest: "f" * 64 },
        { status: "approved" },
        { published_at: 1.day.from_now }
      ].each do |mutation|
        expect do
          ActiveRecord::Base.connection.transaction(requires_new: true) do
            described_class.where(id: disclosure.id).update_all(mutation)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /delivery_disclosures rows are immutable/)
      end

      expect(disclosure.reload).to have_attributes(
        kind: "w2gu",
        version: DeliveryDisclosures::DraftSeeds::DRAFT_VERSION,
        title: DeliveryDisclosures::DraftSeeds::W2GU_TITLE,
        digest: PINNED_DIGESTS["w2gu"],
        status: "draft",
        published_at: DeliveryDisclosures::DraftSeeds::PUBLISHED_AT
      )
    end

    it "allows withdrawing a consent even after a new approved version row is added, and never treats a draft consent as approved" do
      company = create(:company)
      employee = create(:employee, company: company)
      user = create(:user, company: company, role: "portal_employee")
      link = EmployeeAccountLink.create!(company: company, employee: employee, user: user, status: "active")
      draft = described_class.current_for("pay_statements")

      consent = DeliveryConsent.create!(
        company: company,
        user: user,
        employee: employee,
        employee_account_link: link,
        delivery_disclosure: draft,
        kind: "pay_statements",
        disclosure_version: draft.version,
        disclosure_digest: draft.digest,
        given_at: 1.hour.ago,
        method: "employee_portal_checkbox"
      )

      approved = described_class.create!(
        kind: "pay_statements",
        version: "2027-01-10-approved-1",
        title: "Approved Pay Statement Delivery Consent",
        text: "Counsel-approved pay statement consent wording.",
        status: "approved",
        published_at: Time.current
      )

      # Current disclosure switches to the new approved row; draft stays immutable.
      expect(described_class.current_for("pay_statements")).to eq(approved)
      expect(draft.reload.status).to eq("draft")

      # A consent recorded on the draft NEVER counts as approved, even if every other gate passes.
      expect(
        DeliveryConsents::ElectronicOnlyReadiness.paper_delivery_required?(
          company: company,
          employee: employee,
          kind: "pay_statements",
          disclosure: approved,
          drt_answered: true,
          bounce_tracking_exists: true,
          paper_on_withdrawal_verified: true
        )
      ).to be(true)

      # Withdrawing the existing draft consent still succeeds cleanly.
      expect { consent.update!(withdrawn_at: Time.current, withdrawn_by_user: user) }.not_to raise_error
      expect(consent.reload).to be_withdrawn
    end
  end

  describe "frozen seed digests" do
    it "pins exact SHA-256 digests for both draft versions across DraftSeeds and the seed migration" do
      PINNED_DIGESTS.each do |kind, expected_digest|
        seeded = described_class.find_by!(kind: kind, version: DeliveryDisclosures::DraftSeeds::DRAFT_VERSION)
        expect(seeded.status).to eq("draft")
        expect(seeded.digest).to eq(expected_digest)
        expect(described_class.digest_for(seeded.text)).to eq(expected_digest)

        frozen = SeedDraftDeliveryDisclosures::FROZEN_DISCLOSURES.find { |row| row[:kind] == kind }
        expect(frozen).to be_present
        expect(frozen[:version]).to eq(DeliveryDisclosures::DraftSeeds::DRAFT_VERSION)
        expect(frozen[:digest]).to eq(expected_digest)
        expect(described_class.digest_for(frozen[:text])).to eq(expected_digest)
      end
    end

    it "hashes each runtime DraftSeeds::DEFINITIONS text directly against the pinned digests" do
      expect(DeliveryDisclosures::DraftSeeds::DEFINITIONS.map { |d| d[:kind] }).to match_array(PINNED_DIGESTS.keys)
      DeliveryDisclosures::DraftSeeds::DEFINITIONS.each do |definition|
        expect(described_class.digest_for(definition[:text])).to eq(PINNED_DIGESTS.fetch(definition[:kind]))
      end
    end

    it "runs the frozen seed migration idempotently" do
      expect { SeedDraftDeliveryDisclosures.new.up }.not_to change(described_class, :count)
    end

    it "refuses irreversible rollback of AllowDeliveryConsentInChangesToConfirm" do
      expect { AllowDeliveryConsentInChangesToConfirm.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
