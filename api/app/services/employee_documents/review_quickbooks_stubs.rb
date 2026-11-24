# frozen_string_literal: true

module EmployeeDocuments
  class ReviewQuickbooksStubs
    class Invalid < StandardError; end

    PURPOSE = "review_quickbooks_stub"

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
          net_pay: check.net_pay.to_s("F"), check_number: check.check_number)
        if (original = originals[check.id])
          result.merge(status: original.sha256 == review_claim(match)["sha256"] ? "already_posted" : "conflicting_original")
        else
          result.merge(review_token: verifier.generate(review_claim(match), purpose: PURPOSE, expires_in: 30.minutes))
        end
      end
    end

    # Parse and scan outside the write transaction. Confirm repeats the match
    # against the current source records using only the scanned pages.
    def prepare(tokens:, image_tokens:)
      @image_tokens = image_tokens
      submitted = tokens + image_tokens
      raise Invalid, "Select pages from the current preview." if submitted.empty? || submitted.uniq != submitted

      @claims = submitted.to_h { |token| [ token, verifier.verified(token, purpose: PURPOSE) ] }
      raise Invalid, "This preview expired. Upload the file again." if @claims.value?(nil)

      reviewed_matches
    end

    def confirm
      reviewed_matches.sort_by { |match| match.check.id }.map do |match|
        document = freeze_match(match)
        yield match, document if block_given?
        document
      end
    end

    def cleanup!
      @storage_keys.each do |key|
        R2StorageService.new.delete(key)
      rescue StandardError => error
        Rails.logger.error("QuickBooks stub rollback cleanup failed (#{error.class})")
        Rails.error.report(error, handled: true)
      end
    end

    private

    def reviewed_matches
      by_page = matches.index_by { |match| match.page.number }
      @claims.map do |token, claim|
        match = by_page[claim["page"]]
        raise Invalid, "The PDF or its matches changed. Upload it again." unless match&.check && claim == review_claim(match)

        if match.page.has_image != @image_tokens.include?(token)
          raise Invalid, "Page #{match.page.number} has an image. Check it by eye and tick “I checked this page”."
        end

        match
      end
    end

    def matches
      @pages ||= QuickbooksStubPdf.read(@upload)
      QuickbooksStubMatches.new(@company.id, @pages).call
    end

    def review_claim(match)
      {
        "company" => @company.id, "actor" => @actor.id, "page" => match.page.number,
        "check" => match.check.id, "sha256" => Digest::SHA256.hexdigest(match.page.bytes),
        "has_image" => match.page.has_image
      }
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def freeze_match(match)
      check = match.check
      check.lock!
      existing = EmployeeDocument.find_by(company_id: @company.id, historical_paycheck_id: check.id, revision: 1)
      if existing
        unless existing.sha256 == review_claim(match)["sha256"]
          raise Invalid, "Page #{match.page.number} conflicts with an already posted original. Check the original before retrying."
        end
        return existing
      end

      FreezePdf.call(bytes: match.page.bytes, source: check, revision: 1, posted_at: Time.current) do |key|
        @storage_keys << key
      end
    end
  end
end
