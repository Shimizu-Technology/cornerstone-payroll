# frozen_string_literal: true

require "digest"

class SeedDraftDeliveryDisclosures < ActiveRecord::Migration[8.1]
  DRAFT_VERSION = "2026-11-25-draft-1"
  PUBLISHED_AT = Time.utc(2026, 11, 25, 0, 0, 0)

  FROZEN_DISCLOSURES = [
    {
      kind: "pay_statements",
      version: DRAFT_VERSION,
      title: "Electronic Pay Statement Delivery Consent",
      digest: "2b9953902def45cccc5722527bd5a43902b0501256aafd566eaa3a655110d533",
      text: <<~TEXT.strip
        Purpose and scope
        This consent covers electronic delivery of your pay statements (pay stubs) through the employee app for your employment with your employer under the Guam Uniform Electronic Transactions Act (14 GCA Ch. 10). During the pilot period, paper pay statements continue for everyone even if you give consent; recording your consent now records your preference for future electronic delivery once enabled.

        Paper copies
        You are not required to consent to electronic delivery. If you do not consent, you will continue to receive paper pay statements at no charge. Even if you consent, you may request a paper copy of any pay statement from your employer at no charge.

        Right to withdraw consent
        You may withdraw your consent at any time in one tap inside the employee app under My info, or by notifying your employer. Withdrawal takes effect prospectively and triggers paper delivery for future pay statements, with no fee or penalty.

        How long consent lasts
        Your consent stays in effect until you withdraw it, your employer stops offering electronic pay statements, or your employment ends.

        Keeping contact details current
        Please keep your personal email address and home mailing address current in the employee app under My info, or through your employer, so notices and any paper statements reach you.

        Hardware and software requirements
        To view, download, or print electronic pay statements, you need a phone, tablet, or computer with internet access, a current web browser (such as Safari, Chrome, Edge, or Firefox), an active personal email address for availability notices, and a PDF viewer (such as the viewer built into iOS, Android, Chrome, Safari, or Adobe Acrobat Reader), plus storage or a printer if you choose to save or print copies.
      TEXT
    },
    {
      kind: "w2gu",
      version: DRAFT_VERSION,
      title: "Electronic Form W-2GU Delivery Consent",
      digest: "0b5304525f6585def92c9d805c1df26220887e4437333074563642291cc9fc69",
      text: <<~TEXT.strip
        Paper copy unless you consent
        You are not required to consent to receive Form W-2GU (Guam Wage and Tax Statement) electronically. If you do not give consent, you will receive a paper Form W-2GU as required by law (26 CFR 31.6051-1(j)). During the pilot period, paper copies continue for everyone even if you give consent.

        Scope and duration of consent
        Your consent applies to Form W-2GU, including any corrected Form W-2c if applicable, furnished for the current tax year and each following tax year until you withdraw your consent, your employer stops electronic W-2GU furnishing, or your employment ends.

        How to request a paper copy
        Even after consenting to electronic delivery, you may request a paper copy of your Form W-2GU at any time by asking your employer or contacting Cornerstone Payroll at no charge. Requesting a paper copy does not withdraw your consent unless you also withdraw consent.

        How to withdraw consent and when it takes effect
        You may withdraw your consent at any time in one tap in the employee app under Tax forms or My info, or in writing to your employer. Your withdrawal is confirmed immediately in the app, triggers paper delivery, and takes effect for any Form W-2GU furnished after we receive your withdrawal (and no later than 30 days after receipt for forms not yet furnished). Withdrawal does not apply to a Form W-2GU already furnished electronically before withdrawal took effect.

        Notice of termination of electronic furnishing
        Electronic furnishing of Form W-2GU ends if you withdraw consent, if your employer stops providing electronic W-2GU statements, or when your employment ends. Former employees receive paper copies mailed to their last mailing address on file, and electronic copies posted in the app remain accessible through at least October 15 of the year following the tax year (or longer if your access window remains open).

        How to update your contact information
        Keep your personal email address and home mailing address up to date in the employee app under My info, or by notifying your employer directly. While electronic W-2GU consent is active, email notices telling you when your tax document is available remain turned on so you do not miss your form.

        Hardware and software requirements
        To access, view, download, and print Form W-2GU (PDF), you need an internet-connected phone, tablet, or computer, a current web browser (Safari, Chrome, Edge, or Firefox), an active email account for availability notices, and a PDF reader capable of opening standard PDF files, plus device storage or a printer to retain copies for your tax records. If hardware or software requirements change in a way that creates a material risk you cannot access your Form W-2GU, you will be notified and asked to re-confirm consent.

        Confirming you can open PDF files
        Before your electronic Form W-2GU consent can be recorded, you must open the test PDF provided in this app and enter the confirmation code shown inside it to confirm your device can open electronic W-2GU files.
      TEXT
    }
  ].freeze

  def up
    now = Time.current
    FROZEN_DISCLOSURES.each do |attrs|
      actual_digest = Digest::SHA256.hexdigest(attrs[:text])
      unless actual_digest == attrs[:digest]
        raise "Frozen digest mismatch for #{attrs[:kind]} #{attrs[:version]}: expected #{attrs[:digest]}, got #{actual_digest}"
      end

      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          INSERT INTO delivery_disclosures (kind, version, title, text, digest, status, published_at, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, 'draft', ?, ?, ?)
          ON CONFLICT (kind, version) DO NOTHING
        SQL
        attrs[:kind],
        attrs[:version],
        attrs[:title],
        attrs[:text],
        attrs[:digest],
        PUBLISHED_AT,
        now,
        now
      ])
      execute(sql)
    end
  end

  def down
    sql = ActiveRecord::Base.sanitize_sql_array([
      <<~SQL,
        DELETE FROM delivery_disclosures d
        WHERE d.version = ? AND d.status = 'draft'
          AND NOT EXISTS (SELECT 1 FROM delivery_consents c WHERE c.delivery_disclosure_id = d.id)
      SQL
      DRAFT_VERSION
    ])
    execute(sql)
  end
end
