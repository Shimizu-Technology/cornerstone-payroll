# frozen_string_literal: true

require "rails_helper"

# The email that carries an invoice: its default text, editing it before a
# send and after issue, and the record of what each send said.
RSpec.describe "Invoice email content", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:profile) do
    create(:invoice_billing_profile, organization: company.organization, name: "Cornerstone", legal_name: "Cornerstone Payroll LLC",
                                     numbering_style: "continuing", next_invoice_number: 7052, invoice_number_width: 5,
                                     footer_note: nil)
  end
  let!(:recipient) do
    create(:invoice_recipient, organization: company.organization, company: nil, name: "MoSa's Hot Box, Inc.",
                               email: "billing@mosas.example", payment_terms: "Net 15")
  end

  before do
    [ Api::V1::Admin::InvoicesController, Api::V1::Admin::InvoiceSendSchedulesController,
      Api::V1::Admin::InvoiceRecurrencesController, Api::V1::Admin::InvoicePaymentsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  after do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("invoice-center"))
  end

  def november_invoice(**attributes)
    create(:invoice, :with_line_item, company: company, organization: company.organization, invoice_number: nil,
                                      invoice_billing_profile: profile, invoice_recipient: recipient, payment_terms: "Net 15",
                                      invoice_date: Date.new(2026, 11, 30), service_period_start: Date.new(2026, 11, 1),
                                      service_period_end: Date.new(2026, 11, 30), **attributes)
  end

  def issue(invoice)
    InvoiceArtifactStorageService.new.issue_native!(invoice: invoice, actor: admin_user)
    invoice.reload
  end

  def stub_provider(reference = "email-123")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return("test-key")
    allow(ENV).to receive(:[]).with("INVOICE_MAILER_FROM_EMAIL").and_return("invoices@example.com")
    messages = []
    allow(Resend::Emails).to receive(:send) do |message, **|
      messages << message
      { id: reference }
    end
    messages
  end

  describe "default text" do
    it "names the number, customer and service month, then the amount, due date and thanks" do
      invoice = issue(november_invoice)

      expect(invoice.invoice_number).to eq("07052")
      expect(InvoiceEmailContent.default_subject(invoice)).to eq("Invoice 07052 - MoSa's Hot Box, Inc. - November 2026")
      expect(InvoiceEmailContent.default_body(invoice)).to eq(<<~BODY.chomp)
        Hello,

        Please find attached invoice 07052 for November 2026. The amount due is $300.00, due by December 15, 2026.

        Thank you for your business.
        Cornerstone Payroll LLC
      BODY
    end

    it "uses the sender's footer and reads other periods as months or dates" do
      profile.update!(footer_note: "Mahalo for your business!")
      expect(InvoiceEmailContent.default_body(november_invoice)).to end_with("Mahalo for your business!\nCornerstone Payroll LLC")

      two_months = november_invoice(service_period_start: Date.new(2026, 10, 1), service_period_end: Date.new(2026, 11, 30))
      expect(InvoiceEmailContent.default_subject(two_months)).to end_with(" - October - November 2026")
      across_years = november_invoice(service_period_start: Date.new(2026, 12, 1), service_period_end: Date.new(2027, 1, 31),
                                      invoice_date: Date.new(2027, 1, 31))
      expect(InvoiceEmailContent.default_subject(across_years)).to end_with(" - December 2026 - January 2027")
      partial = november_invoice(service_period_start: Date.new(2026, 11, 3), service_period_end: Date.new(2026, 11, 9))
      expect(InvoiceEmailContent.default_subject(partial)).to end_with(" - November 3, 2026 - November 9, 2026")
    end

    it "previews the number a draft will take and says when it's due on receipt" do
      draft = november_invoice(payment_terms: "Due on receipt")

      expect(draft.invoice_number).to start_with("DRAFT-")
      expect(InvoiceEmailContent.default_subject(draft)).to eq("Invoice 07052 - MoSa's Hot Box, Inc. - November 2026")
      expect(InvoiceEmailContent.default_body(draft)).to include("The amount due is $300.00, due on receipt.")
    end

    it "shows the email and its defaults on the invoice" do
      invoice = issue(november_invoice)

      get "/api/v1/admin/invoices/#{invoice.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("invoice", "email")).to include(
        "subject" => "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026",
        "default_subject" => "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026",
        "subject_customized" => false, "body_customized" => false
      )
    end
  end

  describe "editing an issued invoice's email" do
    it "saves the email without changing the issued PDF or snapshot" do
      invoice = issue(november_invoice)
      snapshot = invoice.snapshot.deep_dup
      artifact = invoice.primary_artifact

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: {
        email_subject: "  Invoice 07052 -\nNovember  ", email_body: "Hi Mo,\n\nYour November invoice is attached."
      }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("invoice", "email")).to include(
        "subject" => "Invoice 07052 - November", "body" => "Hi Mo,\n\nYour November invoice is attached.",
        "subject_customized" => true, "body_customized" => true
      )
      invoice.reload
      expect(invoice.snapshot).to eq(snapshot)
      expect(invoice.primary_artifact).to eq(artifact)
      expect(invoice.artifacts.count).to eq(1)
      expect(invoice.events.where(event_type: "email_updated").sole.metadata).to include("subject" => "Invoice 07052 - November")

      # Whitespace-only differences aren't a change.
      expect do
        patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Invoice 07052 - November " }, as: :json
      end.not_to change(InvoiceEvent.where(event_type: "email_updated"), :count)

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "", email_body: "" }, as: :json
      expect(response.parsed_body.dig("invoice", "email")).to include(
        "subject" => "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026", "subject_customized" => false
      )
    end

    it "changes only the email on an older issued invoice that newer rules would reject" do
      invoice = issue(november_invoice)
      invoice.update_columns(due_date: invoice.invoice_date - 1) # predates the due-date rule

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Invoice 07052" }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(invoice.reload).to have_attributes(email_subject: "Invoice 07052", due_date: Date.new(2026, 11, 29), updated_by_id: admin_user.id)
    end

    it "refuses a voided invoice and an overlong subject" do
      invoice = issue(november_invoice)

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "x" * 301 }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(invoice.reload.email_subject).to be_nil

      invoice.void!(actor: admin_user, reason: "Billed twice")
      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Hello" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("A voided invoice can't be emailed")
    end
  end

  describe "sending" do
    it "sends the subject and message edited in the send panel and keeps them in the delivery history" do
      invoice = issue(november_invoice)
      allow(InvoiceSendJob).to receive(:perform_later)
      messages = stub_provider

      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_now: true,
        subject: "Invoice 07052 - MoSa's - November 2026 (corrected)", body: "Hi Mo,\n\nAttached.\n\nThanks!"
      }, as: :json
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body["invoice_send_schedule"]).to include(
        "subject" => "Invoice 07052 - MoSa's - November 2026 (corrected)", "body" => "Hi Mo,\n\nAttached.\n\nThanks!"
      )
      schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))

      InvoiceScheduledSender.send!(schedule.id)

      expect(messages.sole).to include(subject: "Invoice 07052 - MoSa's - November 2026 (corrected)",
                                       text: "Hi Mo,\n\nAttached.\n\nThanks!")
      delivery = invoice.deliveries.sole
      expect(delivery).to have_attributes(email_subject: "Invoice 07052 - MoSa's - November 2026 (corrected)",
                                          email_body: "Hi Mo,\n\nAttached.\n\nThanks!")
      # Sending doesn't save the panel's text as the invoice's email.
      expect(invoice.reload.email_subject).to be_nil

      get "/api/v1/admin/invoices/#{invoice.id}"
      expect(response.parsed_body.dig("invoice", "deliveries").sole).to include(
        "email_subject" => "Invoice 07052 - MoSa's - November 2026 (corrected)", "email_body" => "Hi Mo,\n\nAttached.\n\nThanks!"
      )
    end

    it "sends the invoice's email as edited after issue, not the text frozen at issue" do
      invoice = november_invoice(email_subject: "Old subject from the draft")
      invoice = issue(invoice)
      expect(invoice.snapshot.dig("invoice", "email_subject")).to eq("Old subject from the draft")
      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "" }, as: :json
      messages = stub_provider

      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601
      }, as: :json
      expect(response.parsed_body["invoice_send_schedule"]).to include("subject" => nil, "body" => nil)
      InvoiceScheduledSender.send!(response.parsed_body.dig("invoice_send_schedule", "id"))

      expect(messages.sole[:subject]).to eq("Invoice 07052 - MoSa's Hot Box, Inc. - November 2026")
      expect(invoice.deliveries.sole).to have_attributes(
        email_subject: "Invoice 07052 - MoSa's Hot Box, Inc. - November 2026",
        email_body: InvoiceEmailContent.default_body(invoice.reload)
      )
    end

    it "changes a pending schedule's subject before it is claimed" do
      invoice = issue(november_invoice)
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.hour.from_now.iso8601, subject: "First"
      }, as: :json
      schedule_id = response.parsed_body.dig("invoice_send_schedule", "id")

      patch "/api/v1/admin/invoice_send_schedules/#{schedule_id}", params: { subject: "Second", body: "New message" }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(InvoiceSendSchedule.find(schedule_id)).to have_attributes(rendered_subject: "Second", rendered_body: "New message")
      expect(invoice.events.where(event_type: "email_schedule_updated").sole.metadata).to include("subject" => "Second")
    end
  end

  describe "recurring drafts" do
    it "start from the default email and report the customer's terms" do
      invoice = issue(november_invoice(email_subject: "Invoice 07052 - November only"))

      get "/api/v1/admin/invoices/#{invoice.id}"
      expect(response.parsed_body.dig("invoice", "recurring_terms")).to eq("payment_terms" => "Net 15", "due_after_days" => 15)

      post "/api/v1/admin/invoice_recurrences", params: {
        source_invoice_id: invoice.id, start_on: "2026-12-01", interval_unit: "month", due_after_days: 30
      }
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body.dig("invoice_recurrence", "due_terms")).to eq("payment_terms" => "Net 15", "due_after_days" => 15)

      InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 12, 1))
      draft = InvoiceRecurrence.find(response.parsed_body.dig("invoice_recurrence", "id")).generated_invoices.sole

      expect(draft).to have_attributes(email_subject: nil, email_body: nil, due_date: Date.new(2026, 12, 16))
      expect(InvoiceEmailContent.default_subject(draft)).to eq("Invoice 07053 - MoSa's Hot Box, Inc. - December 2026")
    end

    it "report no terms for a yearly sender, whose drafts use the days entered" do
      profile.update!(numbering_style: "yearly")
      invoice = issue(november_invoice)

      get "/api/v1/admin/invoices/#{invoice.id}"

      expect(response.parsed_body.dig("invoice", "recurring_terms")).to be_nil
    end
  end

  describe "older rows with text past today's limits" do
    let(:long_subject) { "Invoice 07052 #{'x' * 300}" }

    def legacy_invoice
      issue(november_invoice).tap { |invoice| invoice.update_columns(email_subject: long_subject) }
    end

    it "still takes the final payment and keeps the saved text" do
      invoice = legacy_invoice

      post "/api/v1/admin/invoices/#{invoice.id}/payments", params: { amount: 300, received_on: "2026-12-01", payment_method: "check" }

      expect(response).to have_http_status(:created), response.body
      expect(invoice.reload.balance_due).to eq(0)
      expect(invoice.email_subject).to eq(long_subject)
    end

    it "records an accepted send with a shorter reviewed subject" do
      invoice = legacy_invoice
      messages = stub_provider("email-legacy")
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601, subject: "Invoice 07052", body: "Attached."
      }, as: :json
      schedule_id = response.parsed_body.dig("invoice_send_schedule", "id")

      InvoiceScheduledSender.send!(schedule_id)

      expect(messages.sole[:subject]).to eq("Invoice 07052")
      expect(InvoiceSendSchedule.find(schedule_id)).to have_attributes(status: "sent", provider_reference: "email-legacy")
      expect(invoice.deliveries.sole).to have_attributes(email_subject: "Invoice 07052", provider_reference: "email-legacy")
      expect(invoice.reload.sent_at).to be_present
      expect(invoice.email_subject).to eq(long_subject)
    end

    it "sends and records the long saved subject when the schedule has no reviewed text" do
      invoice = legacy_invoice
      messages = stub_provider
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601
      }, as: :json

      InvoiceScheduledSender.send!(response.parsed_body.dig("invoice_send_schedule", "id"))

      expect(messages.sole[:subject]).to eq(long_subject)
      expect(invoice.deliveries.sole.email_subject).to eq(long_subject)
    end

    it "lets a failed schedule with long frozen text go back to pending" do
      invoice = issue(november_invoice)
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601, subject: "Short"
      }, as: :json
      schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))
      schedule.update_columns(status: "failed", attempts: 1, first_claimed_at: 1.hour.ago, rendered_subject: long_subject,
                              rendered_body: "b" * 10_001, last_error: "provider response lost")

      patch "/api/v1/admin/invoice_send_schedules/#{schedule.id}", params: { retry: true }, as: :json

      expect(response).to have_http_status(:ok), response.body
      expect(schedule.reload).to have_attributes(status: "pending", rendered_subject: long_subject)
    end

    it "still refuses new reviewed text past the limits" do
      invoice = issue(november_invoice)

      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.hour.from_now.iso8601, subject: "x" * 301
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(InvoiceSendSchedule.count).to eq(0)
    end
  end

  describe "claiming a send" do
    it "keeps a default subject within the limit when the bill-to name is very long" do
      recipient.update!(name: "Harbor #{'Bakery ' * 60}LLC")
      invoice = issue(november_invoice)
      subject = InvoiceEmailContent.default_subject(invoice)

      expect(subject.length).to eq(Invoice::EMAIL_SUBJECT_MAX)
      expect(subject).to start_with("Invoice 07052 - Harbor Bakery")
      expect(subject).to end_with("… - November 2026")

      messages = stub_provider
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601
      }, as: :json
      schedule_id = response.parsed_body.dig("invoice_send_schedule", "id")
      InvoiceScheduledSender.send!(schedule_id)

      expect(messages.sole[:subject]).to eq(subject)
      expect(InvoiceSendSchedule.find(schedule_id)).to have_attributes(status: "sent", rendered_subject: subject)
    end

    it "marks a claim that fails as failed and re-raises the original error" do
      invoice = issue(november_invoice)
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.minute.ago.iso8601
      }, as: :json
      schedule_id = response.parsed_body.dig("invoice_send_schedule", "id")
      stub_provider
      # The claim's update! fails validation, leaving unsaved changes behind.
      allow_any_instance_of(InvoiceSendSchedule).to receive(:recipients_are_valid) { |schedule| schedule.errors.add(:recipients, "are unavailable") }

      expect { InvoiceScheduledSender.send!(schedule_id) }.to raise_error(ActiveRecord::RecordInvalid, /Recipients are unavailable/)

      expect(InvoiceSendSchedule.find(schedule_id)).to have_attributes(status: "failed", attempts: 0)
      expect(InvoiceSendSchedule.find(schedule_id).last_error).to include("ActiveRecord::RecordInvalid")
      expect(Resend::Emails).not_to have_received(:send)
      expect(invoice.deliveries).to be_empty
    end
  end

  describe "changing the invoice email after a send is scheduled" do
    def schedule_send(invoice, **text)
      post "/api/v1/admin/invoice_send_schedules", params: {
        invoice_id: invoice.id, recipients: [ "billing@mosas.example" ], send_at: 1.hour.from_now.iso8601, **text
      }, as: :json
      InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))
    end

    it "sends the reviewed text of a schedule that has it, and the current email of one that doesn't" do
      invoice = issue(november_invoice)
      reviewed = schedule_send(invoice, subject: "Reviewed subject", body: "Reviewed body")
      deferred = schedule_send(invoice)
      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Changed later", email_body: "Changed body" }, as: :json
      expect(response).to have_http_status(:ok)
      messages = stub_provider
      [ reviewed, deferred ].each { |schedule| schedule.update_columns(send_at: 1.minute.ago) }

      InvoiceScheduledSender.send!(reviewed.id)
      InvoiceScheduledSender.send!(deferred.id)

      expect(messages.map { |message| [ message[:subject], message[:text] ] })
        .to eq([ [ "Reviewed subject", "Reviewed body" ], [ "Changed later", "Changed body" ] ])
      expect(invoice.deliveries.order(:id).map(&:email_subject)).to eq([ "Reviewed subject", "Changed later" ])
    end
  end

  describe "access" do
    it "requires organization-admin authority to change the email" do
      invoice = issue(november_invoice)
      manager = create(:user, company: company, organization: company.organization, role: "manager")
      allow_any_instance_of(Api::V1::Admin::InvoicesController).to receive(:current_user).and_return(manager)

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Not allowed" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(invoice.reload.email_subject).to be_nil
      expect(invoice.events.where(event_type: "email_updated")).to be_empty
    end

    it "keeps email changes inside the selected financial book" do
      first_book = company.organization.finance_books.find_by!(is_default: true)
      second_book = company.organization.finance_books.create!(name: "Client books", legal_name: "Client books", kind: "organization")
      invoice = issue(november_invoice)
      expect(invoice.finance_book_id).to eq(first_book.id)
      other_book = { "X-Organization-Id" => company.organization_id.to_s, "X-Finance-Book-Id" => second_book.id.to_s }
      own_book = { "X-Organization-Id" => company.organization_id.to_s, "X-Finance-Book-Id" => first_book.id.to_s }

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Wrong book" }, headers: other_book, as: :json
      expect(response).to have_http_status(:not_found)
      expect(invoice.reload.email_subject).to be_nil

      patch "/api/v1/admin/invoices/#{invoice.id}/email", params: { email_subject: "Right book" }, headers: own_book, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(invoice.reload.email_subject).to eq("Right book")
    end
  end
end
