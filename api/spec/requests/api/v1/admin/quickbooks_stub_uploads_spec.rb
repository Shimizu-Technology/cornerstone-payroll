# frozen_string_literal: true

require "rails_helper"

RSpec.describe "QuickBooks original stubs", type: :request do
  let(:company) { create(:company, historical_payroll_enabled: true) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, first_name: "Jesse", last_name: "Example", ssn_encrypted: "111-22-3333") }
  let(:check) { create(:historical_paycheck, employee: employee, source_employee_name: "Example, Jesse") }
  let(:storage) { instance_double(R2StorageService, upload: true, delete: true) }
  let(:root) { "/api/v1/admin/quickbooks_stub_upload" }

  include ActiveSupport::Testing::TimeHelpers

  before do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 24),
      end_date: Date.new(2026, 9, 6), pay_date: Date.new(2026, 9, 10))
    check
    allow_any_instance_of(Api::V1::Admin::QuickbooksStubUploadsController).to receive(:current_user).and_return(admin)
    allow(CompanyFeatures).to receive(:for).with(company).and_return(instance_double(CompanyFeatures, employee_portal_feature?: true))
    allow(R2StorageService).to receive(:new).and_return(storage)
  end

  def pdf(*pages, image: false, nested: false, inline: false)
    bytes = Prawn::Document.new do |pdf|
      pages.each_with_index do |lines, index|
        pdf.start_new_page if index.positive?
        pdf.text(lines)
        add_image(pdf, nested: nested) if image
        if inline
          pdf.add_content("q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 ID x EI Q")
        end
      end
    end.render

    Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/pdf", original_filename: "source.pdf")
  end

  def add_image(pdf, nested:)
    png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aBakAAAAASUVORK5CYII=")
    return pdf.image(StringIO.new(png), width: 10) unless nested

    image, = pdf.build_image_object(StringIO.new(png))
    form = pdf.state.store.ref(Type: :XObject, Subtype: :Form, BBox: [ 0, 0, 10, 10 ],
      Resources: { XObject: { InlineLogo: image } })
    form.stream << "q /InlineLogo Do Q"
    pdf.state.page.xobjects[:Nested] = form
    pdf.add_content("/Nested Do")
  end

  def submit(action, upload:, tokens: [], image_tokens: [], number_tokens: [], review_token: nil)
    post "#{root}/#{action}", params: { upload: upload, review_tokens: tokens, image_review_tokens: image_tokens,
      number_review_tokens: number_tokens, review_token: review_token },
      headers: { "X-Company-Id" => company.id.to_s }
  end

  def page_text
    "Employee: Jesse Example\nPay Date: 01/20/2026\nNet Pay: $900.00"
  end

  it "previews only unambiguous matches and freezes only the reviewed page, idempotently" do
    unrelated = "Employee: Different Name\nPay Date: 01/20/2026\nNet Pay: $900.00"
    expect { submit("preview", upload: pdf(page_text, unrelated)) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:ok), response.body
    pages = response.parsed_body.fetch("data")
    expect(pages).to match([
      include("page" => 1, "status" => "matched", "employee_name" => employee.full_name, "check_number" => nil),
      { "page" => 2, "status" => "unmatched" }
    ])
    token = pages.first.fetch("review_token")
    expect { submit("confirm", upload: pdf(page_text, unrelated), tokens: [ token ]) }.to change(EmployeeDocument, :count).by(1)
    expect(response).to have_http_status(:ok), response.body
    doc = EmployeeDocument.find_by!(historical_paycheck: check)
    expect(storage).to have_received(:upload).with(doc.storage_key, satisfy do |bytes|
      output = PDF::Reader.new(StringIO.new(bytes))
      output.page_count == 1 && output.page(1).text.include?("Jesse Example") && Digest::SHA256.hexdigest(bytes) == doc.sha256
    end, content_type: "application/pdf").once
    expect { submit("confirm", upload: pdf(page_text, unrelated), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:ok), response.body
    expect(AuditLog.where(company: company).pluck(:action)).to include(
      "quickbooks_stub_uploads#upload", "quickbooks_stub_uploads#preview",
      "quickbooks_stub_uploads#confirm_requested", "quickbooks_stub_uploads#confirmed"
    )
  end

  it "blocks a full SSN and a substituted upload before storage" do
    submit("preview", upload: pdf(page_text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")

    with_ssn = "#{page_text}\nSSN: 111-22-3333"
    submit("preview", upload: pdf(with_ssn, "#{page_text}\nSSN: 111223333"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq([
      { "page" => 1, "status" => "full_ssn" }, { "page" => 2, "status" => "full_ssn" }
    ])
    expect { submit("confirm", upload: pdf(with_ssn), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(storage).not_to have_received(:upload)
  end

  it "blocks spaced digits, slash and underscore separators, and excludes labeled routing numbers" do
    variants = [ "1 1 1 - 2 2 - 3 3 3 3", "111/22/3333", "111_22_3333" ]
    submit("preview", upload: pdf(*variants.map { |ssn| "#{page_text}\nSSN: #{ssn}" }, "#{page_text}\nRouting 121000358"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("status")).to eq(%w[full_ssn full_ssn full_ssn matched])
    expect(storage).not_to have_received(:upload)
  end

  [ false, true ].each do |nested|
    it "requires and audits visual review of an image #{nested ? 'inside a form' : 'on the page'}" do
      upload = -> { pdf(page_text, image: true, nested: nested) }
      submit("preview", upload: upload.call)
      expect(response).to have_http_status(:ok), response.body
      page = response.parsed_body.fetch("data").first
      expect(page.fetch("status")).to eq("image_review")
      token = page.fetch("review_token")

      expect { submit("confirm", upload: upload.call, tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect { submit("confirm", upload: upload.call, image_tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
      submit("view_page", upload: upload.call, review_token: token)
      expect(response).to have_http_status(:ok), response.body
      expect(PDF::Reader.new(StringIO.new(response.body)).page_count).to eq(1)
      expect { submit("confirm", upload: upload.call, image_tokens: [ token ]) }.to change(EmployeeDocument, :count).by(1)
      expect(response).to have_http_status(:ok), response.body
      expect(AuditLog.find_by!(company: company, action: "quickbooks_stub_uploads#image_reviewed").metadata).to include("page" => 1)
    end
  end

  it "marks an inline image for visual review" do
    submit("preview", upload: pdf(page_text, inline: true))
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data").first).to include("status" => "image_review")
  end

  it "requires its own attestation and an audited view before posting a possible SSN" do
    text = "#{page_text}\nSSN: 123 / 45 / 6789 40"
    submit("preview", upload: pdf(text))
    page = response.parsed_body.fetch("data").first
    expect(page.fetch("status")).to eq("possible_ssn")
    token = page.fetch("review_token")
    submit("confirm", upload: pdf(text), number_tokens: [ token ])
    expect(response).to have_http_status(:unprocessable_entity)

    submit("view_page", upload: pdf(text), review_token: token)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    submit("confirm", upload: pdf(text), image_tokens: [ token ])
    expect(response).to have_http_status(:unprocessable_entity)
    expect { submit("confirm", upload: pdf(text), number_tokens: [ token ]) }.to change(EmployeeDocument, :count).by(1)
    expect(AuditLog.find_by!(company: company, action: "quickbooks_stub_uploads#possible_ssn_reviewed").metadata).to include("page" => 1)
  end

  it "keeps the page preview staff-scoped" do
    text = "#{page_text}\nSSN: 123-45-6789"
    submit("preview", upload: pdf(text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")
    admin.update!(role: "accountant")
    submit("view_page", upload: pdf(text), review_token: token)
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects a remap between the preliminary match and confirmation even when the new employee has the same name" do
    submit("preview", upload: pdf(page_text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")
    replacement = create(:employee, company: company, first_name: employee.first_name, last_name: employee.last_name)
    batch = check.historical_import_batch
    allow_any_instance_of(EmployeeDocuments::ReviewQuickbooksStubs).to receive(:prepare).and_wrap_original do |prepare, **options|
      prepare.call(**options)
      batch.update_columns(status: "previewed")
      QuickbooksHistory::MappingService.new(worker: check.historical_worker, employee: replacement, actor: admin).call
      batch.update_columns(status: "locked")
    end

    expect { submit("confirm", upload: pdf(page_text), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(check.reload.employee_id).to eq(replacement.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("This check's employee changed. Review the page again.")
    expect(storage).not_to have_received(:upload)
  end

  it "rejects a batch returned to preview before confirmation locks its source records" do
    submit("preview", upload: pdf(page_text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")
    allow_any_instance_of(EmployeeDocuments::ReviewQuickbooksStubs).to receive(:prepare).and_wrap_original do |prepare, **options|
      prepare.call(**options)
      check.historical_import_batch.update_columns(status: "previewed")
    end

    expect { submit("confirm", upload: pdf(page_text), tokens: [ token ]) }.not_to change(EmployeeDocument, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("This check's employee changed. Review the page again.")
    expect(storage).not_to have_received(:upload)
  end

  it "identifies an already posted page and an expired preview" do
    submit("preview", upload: pdf(page_text))
    token = response.parsed_body.fetch("data").first.fetch("review_token")
    submit("confirm", upload: pdf(page_text), tokens: [ token ])
    expect(response).to have_http_status(:ok)
    submit("preview", upload: pdf(page_text))
    expect(response.parsed_body.fetch("data").first).to include("status" => "already_posted")
    travel 31.minutes do
      submit("confirm", upload: pdf(page_text), tokens: [ token ])
      expect(response.parsed_body.fetch("error")).to eq("This preview expired. Upload the file again.")
    end
  end

  it "cleans up newly uploaded objects when a later page conflicts" do
    next_check = create(:historical_paycheck, employee: employee, pay_date: Date.new(2026, 1, 21))
    next_text = page_text.sub("01/20/2026", "01/21/2026")
    submit("preview", upload: pdf(page_text, next_text))
    tokens = response.parsed_body.fetch("data").pluck("review_token")
    EmployeeDocument.create!(company: company, historical_paycheck: next_check, revision: 1,
      storage_key: "prior.pdf", sha256: "a" * 64, posted_at: Time.current)

    expect { submit("confirm", upload: pdf(page_text, next_text), tokens: tokens) }.not_to change(EmployeeDocument, :count)
    expect(response.parsed_body.fetch("error")).to start_with("Page 2 conflicts")
    expect(storage).to have_received(:delete).with(include("/historical_paycheck_#{check.id}/")).once
    expect(storage).not_to have_received(:delete).with("prior.pdf")
  end

  it "uses a supplied check number to resolve same-day same-amount checks" do
    check.update_columns(check_number: "120")
    create(:historical_paycheck, employee: employee, check_number: "124")
    submit("preview", upload: pdf(page_text, "#{page_text}\nCheck Number: 124"))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to match([
      { "page" => 1, "status" => "ambiguous" }, include("page" => 2, "status" => "matched", "check_number" => "124")
    ])
  end

  it "does not surface a malformed historical link to an employee of another company" do
    check.update_columns(employee_id: create(:employee, first_name: "Jesse", last_name: "Example").id)
    submit("preview", upload: pdf(page_text))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq([ { "page" => 1, "status" => "unmatched" } ])
  end

  it "rejects staff without the historical import permission" do
    admin.update!(role: "accountant")
    submit("preview", upload: pdf(page_text))
    expect(response).to have_http_status(:forbidden)
  end
end
