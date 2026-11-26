# frozen_string_literal: true

module Parity
  # Shared request-spec setup with real Clerk JWT verification, strict RLS guard,
  # and an in-memory R2 double so frozen employee pay stubs and W-2GU copies are
  # generated and served through the real controllers.
  module ParityContext
    extend ActiveSupport::Concern

    # Generate one 2048-bit RSA keypair per RSpec process instead of per example.
    SHARED_RSA_KEY = OpenSSL::PKey::RSA.generate(2048)

    included do
      include EmployeeLinkHelpers
      include Parity::CanonicalSchema

      let(:link_signing_key) { Parity::ParityContext::SHARED_RSA_KEY }
      let(:stored_pdfs) { {} }
      let(:r2_storage) { instance_double(R2StorageService) }
      let(:pay_stub_pdf_extractor) { Parity::Extractors::PayStubPdfExtractor.new }
      let(:check_stub_pdf_extractor) { Parity::Extractors::CheckStubPdfExtractor.new }
      let(:include_w2_copies) { false }
      let(:include_future_period) { false }
      let(:fixture_scenarios) { :all }
      let(:fixture) do
        Parity::FixtureBuilder.new(
          stored_pdfs: stored_pdfs,
          include_w2: include_w2_copies,
          scenarios: fixture_scenarios,
          include_future_period: include_future_period
        ).build!
      end

      before do
        allow(R2StorageService).to receive(:new).and_return(r2_storage)
        allow(r2_storage).to receive(:upload) { |key, bytes, **| stored_pdfs[key] = bytes.dup.b }
        allow(r2_storage).to receive(:download) { |key| stored_pdfs[key] }
        allow(r2_storage).to receive(:delete) { |key| stored_pdfs.delete(key) }
        fixture
      end

      def employee_headers_for(key)
        bearer("user_parity_#{key}").merge("X-Employee-Link-Id" => fixture.links.fetch(key).id.to_s)
      end

      def client_headers
        bearer("user_parity_client").merge("X-Company-Id" => fixture.company.id.to_s)
      end

      def staff_headers
        bearer("user_parity_staff").merge("X-Company-Id" => fixture.company.id.to_s)
      end

      def employee_api(key)
        Parity::Extractors::EmployeeApiExtractor.new(request_context: self, headers: employee_headers_for(key))
      end

      def client_api
        Parity::Extractors::ClientApiExtractor.new(request_context: self, headers: client_headers)
      end

      def staff_api
        Parity::Extractors::StaffApiExtractor.new(request_context: self, headers: staff_headers)
      end

      def extract_all_paycheck_views(employee_key:, item_key:, period:)
        employee = fixture.employees.fetch(employee_key)
        item = fixture.items.fetch(item_key)
        document = fixture.ensure_stub_posted!(item_key)

        emp_api = employee_api(employee_key)
        emp_data = if document
          emp_api.extract_paycheck(statement_id: document.id, list_year: Parity::FixtureBuilder::TAX_YEAR)
        else
          { status: { visible: false } }
        end

        emp_pdf_bytes = document && emp_api.statement_pdf_bytes(document.id)
        emp_pdf = emp_pdf_bytes ? pay_stub_pdf_extractor.extract(emp_pdf_bytes) : nil

        cli_period = client_api.extract_pay_period_item(pay_period_id: period.id, employee_id: employee.id)
        cli_history = client_api.extract_pay_history_item(
          employee_id: employee.id,
          year: Parity::FixtureBuilder::TAX_YEAR,
          payroll_item_id: item.id
        )
        cli_pdf_bytes = client_api.pay_stub_pdf_bytes(item.id)
        cli_pdf = cli_pdf_bytes ? pay_stub_pdf_extractor.extract(cli_pdf_bytes) : nil

        stf_period = staff_api.extract_pay_run_item(pay_period_id: period.id, employee_id: employee.id)
        stf_history = staff_api.extract_pay_history_item(
          employee_id: employee.id,
          year: Parity::FixtureBuilder::TAX_YEAR,
          payroll_item_id: item.id
        )

        chk_pdf = if item.effective_payment_delivery_method == "paper_check" && item.net_pay.to_d.positive?
          bytes = item.voided? ? CheckGenerator.new(item).generate_voided : staff_api.check_pdf_bytes(item.id)
          check_stub_pdf_extractor.extract(bytes)
        end

        {
          employee_api: emp_data,
          employee_stub_pdf: emp_pdf,
          client_pay_period: cli_period,
          client_pay_history: cli_history,
          client_stub_pdf: cli_pdf,
          staff_pay_period: stf_period,
          staff_pay_history: stf_history,
          check_stub_pdf: chk_pdf
        }.compact
      end
    end
  end
end
