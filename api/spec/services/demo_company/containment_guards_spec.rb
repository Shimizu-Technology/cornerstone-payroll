# frozen_string_literal: true

require "rails_helper"

# Model, service and database guards that keep a demo company's records out of
# filings, payments, liabilities, integrations and firm billing even when a
# caller skips the controllers.
RSpec.describe "Demo company containment guards" do
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization, name: "Live Client") }
  let(:demo) { create_demo_company(organization: organization) }
  let(:admin) { create(:user, company: live, organization: organization, role: "admin") }
  let(:demo_employee) { create(:employee, company: demo, department: create(:department, company: demo), ssn_encrypted: "900-01-0003") }
  let(:period) { create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee) }

  def raw_insert(table, columns)
    names = columns.keys.join(", ")
    values = columns.values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(", ")
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("INSERT INTO #{table} (#{names}, created_at, updated_at) VALUES (#{values}, NOW(), NOW())")
    end
  end

  describe "filing evidence" do
    it "refuses a demo filing record and event in the model and in the database" do
      record = PayrollFilingRecord.new(company: demo, filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026, status: "submitted",
        submitted_at: Time.current, confirmation_number: "CONF", source_fingerprint: "a" * 64)
      expect(record).not_to be_valid
      expect(record.errors.full_messages).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
      expect(PayrollFilingEvent.new(company: demo)).to have_attributes(valid?: false)

      expect do
        raw_insert("payroll_filing_records", company_id: demo.id, filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026,
          status: "submitted", submitted_at: Time.current, confirmation_number: "CONF", source_fingerprint: "a" * 64)
      end.to raise_error(ActiveRecord::StatementInvalid, /cannot belong to a demo company/)

      live_record = PayrollFilingRecord.create!(company: live, filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026, status: "submitted",
        submitted_at: Time.current, confirmation_number: "CONF", source_fingerprint: "a" * 64)
      expect { ActiveRecord::Base.transaction(requires_new: true) { live_record.update_columns(company_id: demo.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot belong to a demo company/)
    end
  end

  describe "Form 500" do
    let(:filing) { Form500Filing.new(company: demo, pay_period: period, fields: { "company_name" => demo.name }, status: "prepared") }

    it "records preparation only for a demo" do
      expect(filing).to be_valid
      { status: "filed" }.merge(status: "paid").each do |attribute, value|
        filing.assign_attributes(attribute => value)
        expect(filing).not_to be_valid
      end
      [ { payment_amount: 10 }, { payment_date: Date.current }, { confirmation_number: "DRT-1" }, { receipt_attached: true } ].each do |change|
        candidate = Form500Filing.new(company: demo, pay_period: period, fields: { "x" => 1 }, status: "prepared", **change)
        expect(candidate).not_to be_valid, "accepted #{change.inspect}"
        expect(candidate.errors.full_messages).to include(Company::DEMO_UNAVAILABLE_MESSAGE)
      end
    end
  end

  describe "liability postings, FIT checks and AIRE" do
    it "posts no live liability for a demo commit" do
      expect(PayrollLiabilityPostingService.post!(pay_period: period, actor: admin)).to be_nil
      expect(PayrollLiabilityPosting.where(company: demo)).to be_empty
      expect(PayrollLiabilityPosting.new(company: demo)).to have_attributes(valid?: false)
      expect do
        raw_insert("payroll_liability_postings", company_id: demo.id, pay_period_id: period.id, posting_type: "commit",
          idempotency_key: "raw-demo", liability_date: Date.current, posted_at: Time.current)
      end.to raise_error(ActiveRecord::StatementInvalid, /cannot belong to a demo company/)
    end

    it "never creates a FIT deposit check or AIRE acknowledgements for a demo" do
      service = PayPeriodLifecycleService.new(pay_period: period, actor: admin)
      expect(service.send(:create_fit_tax_deposit_check!, period.payroll_items.to_a)).to be_nil
      expect(service.send(:record_aire_processing_acknowledgements)).to eq(batch: [], entries: [])
      expect(NonEmployeeCheck.where(company: demo)).to be_empty
      demo.auto_create_fit_check = true
      expect(demo).not_to be_valid
    end

    it "refuses an external time-tracking source for a demo" do
      expect(build(:time_tracking_source, company: demo)).not_to be_valid
      source = create(:time_tracking_source, company: live)
      expect { ActiveRecord::Base.transaction(requires_new: true) { source.update_columns(company_id: demo.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot belong to a demo company/)
    end

    it "refuses outbound AIRE traffic for a demo even with a stale source" do
      stale = build(:time_tracking_source, company: demo)
      expect { TimeTracking::Client.new(stale) }.to raise_error(TimeTracking::Client::Error, Company::DEMO_UNAVAILABLE_MESSAGE)
    end
  end

  describe "check output" do
    it "refuses demo print runs and preprinted bank stock" do
      expect { FirstHawaiianFourUpCheckGenerator.new(company: demo, payroll_items: []) }
        .to raise_error(ArgumentError, Company::DEMO_UNAVAILABLE_MESSAGE)
      demo.check_stock_type = "first_hawaiian_4up"
      expect(demo).not_to be_valid

      service = CheckPrintRunGenerationService.allocate
      service.instance_variable_set(:@pay_period, period)
      expect { service.send(:validate_request!) }.to raise_error(CheckPrintRunGenerationService::InvalidSelectionError, Company::DEMO_UNAVAILABLE_MESSAGE)
    end
  end

  describe "electronic filing exports" do
    before { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }

    it "refuses the EFW2 and Pub 1220 files at the generator" do
      report = W2GuAggregator.new(demo, 2026).generate
      expect { Efw2W2GuGenerator.new(company: demo, year: 2026, submitter: nil, report: report).generate }
        .to raise_error(ArgumentError, Company::DEMO_UNAVAILABLE_MESSAGE)
      expect { Form1099Pub1220Generator.new(company: demo, year: 2026, submitter: nil, draft: true).generate }
        .to raise_error(ArgumentError, Company::DEMO_UNAVAILABLE_MESSAGE)
    end

    it "renders 1096 totals from payee totals without an e-file" do
      totals = Form1099Pub1220Generator.new(company: demo, year: 2026, submitter: nil, draft: false).payee_totals
      expect(totals).to eq(forms: 0, box1_cents: 0, box4_cents: 0)
      pdf = Form1096TotalsPdfGenerator.new(company: demo, totals: { forms: 2, box1_cents: 123_456, box4_cents: 0 }, draft: false).generate
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")
      expect(text).to include("Total forms: 2", "1,234.56")
      expect(text).not_to match(/DRAFT|practice|demo/i)
    end
  end

  describe "billing profile" do
    it "never takes firm contact details from a demo company" do
      demo.update!(phone: "6715550100", email: "kitchen@demo-mail.example")
      live.update!(phone: "6715550199", email: "office@firm.example")
      organization.update_columns(primary_company_id: demo.id)
      book = FinanceBook.create!(organization: organization, name: "Second book", legal_name: "Second book", kind: "organization")
      profile = InvoiceBillingProfile.ensure_default_for!(organization, finance_book: book)
      expect(profile.phone).to eq("6715550199")
      expect(profile.email).to eq("office@firm.example")
      expect(organization.reload).not_to be_valid
    end
  end
end
