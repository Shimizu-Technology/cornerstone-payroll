# frozen_string_literal: true

module EmployeeDocuments
  # Posts a company's W-2GU employee copies (Copy B over Copy C, with the IRS
  # notice behind) to the employee app for one tax year (M4-5). Each employee
  # gets their own frozen PDF in employee_documents, with the tax_year as its
  # source and a SHA-256 fingerprint, like the pay stubs (D7).
  #
  # Nothing posts unless the staff download would print the same copies as
  # final: Cornerstone files the year's W-2s, the W-2 readiness mark is
  # current on these exact inputs, the filing-responsibility gate allows
  # filing-ready output, and every value fits the form. The company's
  # employee_portal.features.tax_forms switch must be on.
  #
  # Idempotent: an employee who already has a copy for the year (posted or
  # withdrawn) is skipped, so a rerun posts only what is missing and a
  # withdrawn copy stays withdrawn until W-2c exists.
  #
  # The PDFs are drawn and uploaded before any lock is held. Then the company
  # lock (mark-ready and preflight take it too) and a shared lock on the
  # year's annual tax rules (whose SS wage base is in the fingerprint) are
  # taken in the payroll lock order, the inputs are read again uncached, and
  # the rows commit under those locks. If anything changed, nothing posts and
  # the uploads are removed.
  #
  # Each new copy's pending notice row commits with it; after commit the
  # notice dispatcher sends it (and its sweep retries anything left). A
  # rerun also adds a pending notice for any posted copy that has none.
  class PostW2GuCopies
    Result = Struct.new(:status, :documents, :problems, keyword_init: true) do
      def posted_count
        documents.size
      end
    end

    STATUSES = %i[posted feature_off unsupported_year not_filed not_final does_not_fit changed].freeze

    def initialize(company:, year:, user: nil, actor: nil)
      @company = company
      @year = year.to_i
      @user = user
      @actor = actor || (AuditActor.for_user(user) if user) || Current.actor
    end

    # Why posting can't run now, or nil. Cheap enough for the staff screen.
    def blocker
      return :feature_off unless CompanyFeatures.for(@company).employee_portal_feature?(:tax_forms)
      return :unsupported_year unless W2GuOfficialCopies.supported_tax_year?(@year)

      nil
    end

    def posting_pending?
      return false if blocker

      snapshot = W2GuOfficialCopies.snapshot(@company, @year)
      snapshot[:final] && pending_employee_ids(snapshot.fetch(:report)).any?
    end

    def call
      if (reason = blocker)
        return result(reason)
      end

      snapshot = @company.with_lock { W2GuOfficialCopies.snapshot(@company, @year) }
      return result(:not_filed) unless snapshot[:cornerstone_files]
      return result(:not_final) unless snapshot[:final]

      report = snapshot[:report]
      copies(report).ensure_fits!
      pdfs = pending_employee_ids(report).index_with { |employee_id| copies(report, employee_id).generate }
      documents = with_staged_uploads(pdfs) { |staged| post!(snapshot, staged) }
      return result(:changed) if documents == :changed

      result(:posted, documents)
    rescue W2GuOfficialCopies::DoesNotFit => e
      result(:does_not_fit, [], e.problems)
    end

    private

    def result(status, documents = [], problems = [])
      Result.new(status: status, documents: documents, problems: problems)
    end

    def copies(report, employee_id = nil)
      W2GuOfficialCopies.new(company: @company, report: report, kind: "employee", draft: false, employee_id: employee_id)
    end

    def documented_employee_ids
      EmployeeDocument.where(company_id: @company.id, tax_year: @year).order(:employee_id).distinct.pluck(:employee_id).to_set
    end

    def pending_employee_ids(report)
      done = documented_employee_ids
      Array(report[:employees]).map { |row| row[:employee_id] }.reject { |id| done.include?(id) }.sort
    end

    # Uploads each copy before the locks, then removes every upload that
    # didn't end up in a committed row (a change, a rerun that raced this
    # one, or an error).
    def with_staged_uploads(pdfs)
      employees = Employee.where(company_id: @company.id, id: pdfs.keys).index_by(&:id)
      staged = {}
      kept = []
      begin
        pdfs.each do |employee_id, bytes|
          employee = employees[employee_id]
          next unless employee

          staged[employee_id] = FreezePdf.stage(bytes: bytes, source: employee, revision: 1, tax_year: @year)
        end
        outcome = yield staged
        kept = outcome.map(&:storage_key) if outcome.is_a?(Array)
        outcome
      ensure
        staged.each_value { |upload| FreezePdf.remove_uncommitted_object(upload.key) unless kept.include?(upload.key) }
      end
    end

    def post!(snapshot, staged)
      @company.with_lock do
        # Payroll lock order: company, then the year's annual rules.
        AnnualTaxConfig.where(tax_year: @year).order(:id).lock("FOR SHARE").load
        recheck = ActiveRecord::Base.uncached { W2GuOfficialCopies.snapshot(@company, @year) }
        next :changed if W2GuOfficialCopies.snapshot_signature(recheck) != W2GuOfficialCopies.snapshot_signature(snapshot)
        # Feature or year could have changed while the PDFs were drawn.
        next :changed if blocker

        done = documented_employee_ids
        employees = Employee.where(company_id: @company.id, id: staged.keys).order(:id).index_by(&:id)
        posted_at = Time.current
        documents = staged.sort.filter_map do |employee_id, upload|
          employee = employees[employee_id]
          next if employee.nil? || done.include?(employee_id)

          # The W-2 inputs the copy was drawn from, so staff can see when
          # the figures change after posting (a copy is never reposted).
          facts = { payroll_facts_sha256: snapshot[:fingerprint], payroll_facts_checked_at: posted_at }
          document = FreezePdf.record_staged!(upload, source: employee, tax_year: @year, posted_at: posted_at, revision: 1,
            payroll_facts: facts)
          TaxFormRetention.extend_former_access!(employee: employee, tax_year: @year, actor: @actor, user: @user)
          document
        end
        # An outer transaction that rolls back takes the rows with it.
        keys = documents.map(&:storage_key)
        EmployeeDocument.current_transaction.after_rollback { keys.each { |key| FreezePdf.remove_uncommitted_object(key) } }
        audit!(documents, snapshot) if documents.any?
        unsent = TaxFormNotice.ensure_pending!(company: @company, tax_year: @year)
        EmployeeDocument.current_transaction.after_commit { DispatchEmployeeTaxFormNoticesJob.perform_later(@company.id) } if unsent.positive?
        documents
      end
    end

    def audit!(documents, snapshot)
      AuditLog.record!(
        user: @user, actor: @actor, organization_id: @company.organization_id, company_id: @company.id,
        action: "employee_tax_forms#posted", record_type: "Company", record_id: @company.id,
        subject_name: "#{@year} W-2GU employee copies", event_category: "employee_portal",
        metadata: {
          tax_year: @year, document_kind: "w2_gu_employee_copies_b_c", posted_count: documents.size,
          employee_document_ids: documents.map(&:id), inputs_fingerprint: snapshot[:fingerprint],
          ready_fingerprint: snapshot[:readiness]&.ready_fingerprint
        }
      )
    end
  end
end
