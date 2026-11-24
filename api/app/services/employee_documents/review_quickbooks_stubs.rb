# frozen_string_literal: true

module EmployeeDocuments
  class ReviewQuickbooksStubs
    class Invalid < StandardError; end

    PURPOSE = "review_quickbooks_stub"

    def initialize(company:, actor:, upload:)
      @company = company
      @actor = actor
      @upload = upload
    end

    def preview
      matches.map do |match|
        result = { page: match.page.number, status: match.status }
        next result unless match.check

        check = match.check
        result.merge(
          employee_name: check.employee.full_name, pay_date: check.pay_date,
          net_pay: check.net_pay.to_s("F"), check_number: check.check_number,
          review_token: verifier.generate(review_claim(match), purpose: PURPOSE, expires_in: 30.minutes)
        )
      end
    end

    def confirm(tokens)
      claims = tokens.map { |token| verifier.verified(token, purpose: PURPOSE) }
      raise Invalid, "Select pages from the current preview." if claims.blank? || claims.any?(&:nil?) || claims.uniq != claims

      by_page = matches.index_by { |match| match.page.number }
      reviewed = claims.map do |claim|
        match = by_page[claim["page"]]
        raise Invalid, "The PDF or its matches changed. Preview it again." unless match&.check && claim == review_claim(match)

        match
      end

      EmployeeDocument.transaction do
        reviewed.sort_by { |match| match.check.id }.map { |match| freeze_match(match) }
      end
    end

    private

    def matches
      pages = QuickbooksStubPdf.read(@upload)
      QuickbooksStubMatches.new(@company.id, pages).call
    end

    def review_claim(match)
      {
        "company" => @company.id, "actor" => @actor.id, "page" => match.page.number,
        "check" => match.check.id, "sha256" => Digest::SHA256.hexdigest(match.page.bytes)
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
        raise Invalid, "A different original is already posted for a selected check." unless existing.sha256 == review_claim(match).fetch("sha256")

        return existing
      end

      FreezePdf.call(bytes: match.page.bytes, source: check, revision: 1, posted_at: Time.current)
    end
  end
end
