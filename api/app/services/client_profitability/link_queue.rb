# frozen_string_literal: true

module ClientProfitability
  # Every Tax client and Tax user seen in stored hours, how each is linked in
  # Payroll, and a suggested match for the ones that aren't linked yet.
  class LinkQueue
    COMPANY_WORDS = %w[inc incorporated llc ltd limited corp corporation co company the dba pllc pc].freeze

    def initialize(organization:, settings: ClientProfitabilitySetting.for(organization))
      @organization = organization
      @settings = settings
    end

    def call
      { clients: clients, staff: staff, companies: company_options, recipients: recipient_options, employees: employee_options }
    end

    def companies
      @companies ||= Company.where(organization_id: @organization.id).live_payroll.order(:name).to_a
    end

    # Invoice customers with no Payroll client, from the book the report
    # reads fees from.
    def recipients
      @recipients ||= begin
        book = @settings.effective_finance_book
        book ? InvoiceRecipient.where(organization_id: @organization.id, finance_book_id: book.id, company_id: nil, active: true).order(:name).to_a : []
      end
    end

    def practice_employees
      @practice_employees ||= if (company = @settings.effective_practice_company)
        Employee.where(company_id: company.id).order(:last_name, :first_name).to_a
      else
        []
      end
    end

    private

    def rows
      WorkHourRow.where(organization_id: @organization.id)
    end

    def clients
      links = WorkHourClientLink.active.where(organization_id: @organization.id).includes(:invoice_recipient)
                                .where("company_id IS NULL OR company_id IN (?)", Company.where(organization_id: @organization.id).select(:id))
                                .where("invoice_recipient_id IS NULL OR invoice_recipient_id IN (?)",
                                       InvoiceRecipient.where(organization_id: @organization.id,
                                                              finance_book_id: @settings.effective_finance_book&.id).select(:id))
                                .index_by(&:tax_client_id)
      stats = rows.where(unassigned: false).where.not(tax_client_id: nil).group(:tax_client_id)
                  .pluck(:tax_client_id, Arel.sql("SUM(hours)"), Arel.sql("MAX(work_date)"), Arel.sql("BOOL_OR(system_kind = 'internal')"))
      names = latest_names
      company_names = companies.to_h { |company| [ company.id, company.name ] }
      ids = (stats.map(&:first) + links.keys).uniq

      ids.map do |tax_client_id|
        _id, hours, last_worked_on, internal = stats.find { |stat| stat.first == tax_client_id }
        link = links[tax_client_id]
        name = names[tax_client_id] || link&.tax_client_name || "Tax client ##{tax_client_id}"
        {
          tax_client_id: tax_client_id,
          name: name,
          hours: format("%.2f", hours.to_d),
          last_worked_on: last_worked_on&.iso8601,
          internal_in_tax: internal == true,
          link: link && { disposition: link.disposition, company_id: link.company_id, company_name: company_names[link.company_id],
                          invoice_recipient_id: link.invoice_recipient_id, recipient_name: link.invoice_recipient&.name },
          handled_automatically: link.nil? && internal == true,
          suggestion: link ? nil : client_suggestion(name, internal == true)
        }
      end.sort_by { |client| [ client[:link] || client[:handled_automatically] ? 1 : 0, client[:name].downcase ] }
    end

    def latest_names
      rows.where.not(tax_client_id: nil).order(:work_date, :id).pluck(:tax_client_id, :client_name).to_h
    end

    def client_suggestion(name, internal)
      return { disposition: "internal", label: "Internal / overhead", match: "internal" } if internal

      target = normalize(name)
      return nil if target.empty?

      # Payroll clients first, then invoice customers with no Payroll client.
      candidates = companies.map { |company| [ :company, company ] } + recipients.map { |recipient| [ :recipient, recipient ] }
      exact = candidates.find { |_kind, record| normalize(record.name) == target }
      return suggestion_for(*exact, "exact") if exact

      tokens = target.split
      best = candidates.map { |kind, record| [ kind, record, similarity(tokens, normalize(record.name).split) ] }.max_by(&:last)
      return nil unless best && best.last >= 0.5

      suggestion_for(best[0], best[1], "similar")
    end

    def suggestion_for(kind, record, match)
      if kind == :company
        { disposition: "company", company_id: record.id, label: record.name, match: match }
      else
        { disposition: "recipient", invoice_recipient_id: record.id, label: record.name, match: match }
      end
    end

    def staff
      practice_id = @settings.effective_practice_company&.id
      links = WorkHourStaffLink.active.where(organization_id: @organization.id).includes(:employee)
                               .select { |link| link.disposition == "no_payroll" || link.employee&.company_id == practice_id }
                               .index_by(&:tax_user_id)
      stats = rows.group(:tax_user_id).pluck(:tax_user_id, Arel.sql("SUM(hours)"), Arel.sql("MAX(email)"))
      ids = (stats.map(&:first) + links.keys).uniq

      ids.map do |tax_user_id|
        _id, hours, email = stats.find { |stat| stat.first == tax_user_id }
        link = links[tax_user_id]
        email ||= link&.email
        {
          tax_user_id: tax_user_id,
          email: email,
          hours: format("%.2f", hours.to_d),
          link: link && { disposition: link.disposition, employee_id: link.employee_id, employee_name: link.employee&.full_name,
                          in_practice_company: true },
          suggestion: link ? nil : staff_suggestion(email)
        }
      end.sort_by { |person| [ person[:link] ? 1 : 0, person[:email].to_s ] }
    end

    def staff_suggestion(email)
      return nil if email.blank?

      normalized_email = email.to_s.strip.downcase
      unless EmployeeContactValidator.unmatchable_placeholder_email?(normalized_email, marked_placeholders: marked_placeholders)
        exact_matches = practice_employees.select { |employee| employee.active? && employee.email.to_s.strip.casecmp?(normalized_email) }
        if exact_matches.one?
          exact = exact_matches.first
          return { disposition: "employee", employee_id: exact.id, label: exact.full_name, match: "exact" }
        end
      end

      first = email.split("@").first.to_s.split(/[._\-+]/).first.to_s
      matches = practice_employees.select { |employee| employee.first_name.to_s.strip.casecmp?(first) }
      return nil unless matches.one?

      { disposition: "employee", employee_id: matches.first.id, label: matches.first.full_name, match: "similar" }
    end

    def marked_placeholders
      @marked_placeholders ||= EmployeeContactValidator.marked_placeholder_emails(organization_id: @organization.id)
    end

    def company_options
      companies.map { |company| { id: company.id, name: company.name } }
    end

    def recipient_options
      recipients.map { |recipient| { id: recipient.id, name: recipient.name } }
    end

    def employee_options
      practice_employees.map { |employee| { id: employee.id, name: employee.full_name, status: employee.status } }
    end

    def normalize(name)
      name.to_s.downcase.gsub("&", " and ").gsub(/[^a-z0-9\s]/, " ").split
          .reject { |word| COMPANY_WORDS.include?(word) }.join(" ")
    end

    def similarity(left, right)
      return 0 if left.empty? || right.empty?

      (left & right).length.to_f / (left | right).length
    end
  end
end
