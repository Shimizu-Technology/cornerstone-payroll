# frozen_string_literal: true

module EmployeeDocuments
  class ReviewQuickbooksStubs
    class Invalid < StandardError; end

    PURPOSE = "review_quickbooks_stub"
    MAPPING_CHANGED = "This check's employee changed. Review the page again."

    def initialize(company:, actor:, upload:)
      @company = company
      @actor = actor
      @upload = upload
      @storage_keys = []
    end

    def preview
      found = matches
      originals = EmployeeDocument.where(company_id: @company.id, revision: 1,
        historical_paycheck_id: found.filter_map { |match| match.check&.id }).index_by(&:historical_paycheck_id)

      found.map do |match|
        result = { page: match.page.number, status: match.status }
        next result unless match.check

        check = match.check
        result.merge!(employee_name: check.employee.full_name, pay_date: check.pay_date,
          net_pay: check.net_pay.to_s("F"), check_number: check.check_number, has_image: match.page.has_image)
        if (original = originals[check.id])
          result.merge(status: original.sha256 == review_claim(match)["sha256"] ? "already_posted" : "conflicting_original")
        else
          result.merge(review_token: verifier.generate(review_claim(match), purpose: PURPOSE, expires_in: 30.minutes))
        end
      end
    end

    # Parse and scan outside the write transaction. Confirm repeats the match
    # against the current source records using only the scanned pages.
    def prepare(tokens:, image_tokens:, number_tokens:)
      @token_statuses = { "matched" => tokens, "image_review" => image_tokens, "possible_ssn" => number_tokens }
      submitted = @token_statuses.values.flatten
      raise Invalid, "Select pages from the current preview." if submitted.empty? || submitted.uniq != submitted

      @claims = submitted.to_h { |token| [ token, verifier.verified(token, purpose: PURPOSE) ] }
      raise Invalid, "This preview expired. Upload the file again." if @claims.value?(nil)

      reviewed_matches
    end

    def view_page(token)
      claim = verifier.verified(token, purpose: PURPOSE)
      raise Invalid, "This preview expired. Upload the file again." unless claim

      match = matches.find { |candidate| candidate.page.number == claim["page"] }
      unless match&.check && match.status.in?(%w[image_review possible_ssn]) && claim == review_claim(match)
        raise Invalid, "The PDF or its matches changed. Upload it again."
      end

      match.page
    end

    def confirm(revalidate:)
      locked_checks = lock_sources!
      revalidate.call
      reviewed_matches(locked: true).sort_by { |match| match.check.id }.map do |match|
        document = freeze_match(match.page, locked_checks.fetch(match.check.id))
        yield match, document if block_given?
        document
      end
    end

    def cleanup!
      @storage_keys.each { |key| FreezePdf.remove_uncommitted_object(key) }
    end

    private

    def lock_sources!
      sources = source_checks
      batch_ids, worker_ids = sources.pluck(:historical_import_batch_id, :historical_worker_id).transpose
      # Match MappingService's batch → worker → paycheck lock order. The caller
      # revalidates staff access after these locks, since MappingService locks the actor last.
      batches = HistoricalImportBatch.where(company_id: @company.id, id: batch_ids).order(:id).lock.index_by(&:id)
      HistoricalWorker.where(company_id: @company.id, id: worker_ids).order(:id).lock.load
      checks = sources.order(:id).lock.index_by(&:id)
      @claims.each_value do |claim|
        check = checks[claim.fetch("check")]
        unless check && check.employee_id == claim["employee"] && batches[check.historical_import_batch_id]&.locked?
          raise Invalid, MAPPING_CHANGED
        end
      end
      checks
    end

    def source_checks
      HistoricalPaycheck.where(company_id: @company.id, id: @claims.values.pluck("check"))
    end

    def reviewed_matches(locked: false)
      by_page = matches.index_by { |match| match.page.number }
      @claims.map do |token, claim|
        match = by_page[claim["page"]]
        unless match&.check && claim == review_claim(match)
          if locked || mapping_changed_since_preview?(claim)
            raise Invalid, MAPPING_CHANGED
          end
          raise Invalid, "The PDF or its matches changed. Upload it again."
        end

        unless @token_statuses.fetch(match.status).include?(token) && viewed_if_required?(claim)
          raise Invalid, "Open page #{match.page.number}, review it, and tick “I checked this page”."
        end

        match
      end
    end

    def mapping_changed_since_preview?(claim)
      return false unless claim["company"] == @company.id && claim["actor"] == @actor.id

      source_checks.where(id: claim["check"]).pick(:employee_id) != claim["employee"]
    end

    def viewed_if_required?(claim)
      return true if claim["review_status"] == "matched"

      AuditLog.where(company_id: @company.id, user_id: @actor.id, action: "quickbooks_stub_uploads#review_page_viewed",
        created_at: 30.minutes.ago..)
        .where("metadata @> ?::jsonb", { page: claim.fetch("page"), sha256: claim.fetch("sha256") }.to_json).exists?
    end

    def matches
      @pages ||= QuickbooksStubPdf.read(@upload)
      QuickbooksStubMatches.new(@company.id, @pages).call
    end

    def review_claim(match)
      {
        "company" => @company.id, "actor" => @actor.id, "page" => match.page.number,
        "check" => match.check.id, "employee" => match.check.employee_id, "sha256" => Digest::SHA256.hexdigest(match.page.bytes),
        "review_status" => match.status, "has_image" => match.page.has_image
      }
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def freeze_match(page, check)
      existing = EmployeeDocument.find_by(company_id: @company.id, historical_paycheck_id: check.id, revision: 1)
      if existing
        unless existing.sha256 == Digest::SHA256.hexdigest(page.bytes)
          raise Invalid, "Page #{page.number} conflicts with an already posted original. Check the original before retrying."
        end
        return existing
      end

      FreezePdf.call(bytes: page.bytes, source: check, revision: 1, posted_at: Time.current) do |key|
        @storage_keys << key
      end
    end
  end
end
