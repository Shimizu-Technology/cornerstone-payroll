# frozen_string_literal: true

module ClientProfitability
  # Hours, cost, fees and margin per Payroll client for whole months.
  #
  # Cost: each practice-company employee's payroll cost for paychecks whose pay
  # date falls in the period, taken from AnnualPayrollSummary#
  # payroll_cost_by_employee so the total always equals that report's "total
  # payroll cost" for the same client and dates. It is split across the
  # clients that person logged hours to in the period, in proportion to
  # approved hours (clock hours count as approved). Pending hours are shown
  # and only costed when cost_pending is on.
  #
  # Fees: InvoiceServiceFeeRevenue for the same service months.
  #
  # See docs/CLIENT_PROFITABILITY.md for the rules and their limits.
  class Report
    ZERO = BigDecimal("0")

    Bucket = Struct.new(:key, :kind, :company_id, :invoice_recipient_id, :tax_client_id, :name, keyword_init: true)
    # Lines that are a billed client: a Payroll client, or an invoice
    # customer with no Payroll client that a Tax client is linked to.
    CLIENT_KINDS = %w[company recipient].freeze

    attr_reader :period

    # cost_basis: "pay_date" or "work_period"; nil uses the saved setting.
    def initialize(organization:, period:, settings: ClientProfitabilitySetting.for(organization), cost_pending: false, spread_overhead: false,
                   cost_basis: nil)
      if cost_basis && !ClientProfitabilitySetting::COST_BASES.include?(cost_basis)
        raise ArgumentError, "Count pay by must be pay date or work period"
      end

      @requested_cost_basis = cost_basis
      @organization = organization
      @period = period
      @settings = settings
      @cost_pending = cost_pending
      @spread_overhead = spread_overhead
    end

    def call
      @rows = WorkHourRow.where(organization_id: @organization.id, work_date: @period.range).to_a
      @practice_company = @settings.effective_practice_company
      # Only active links, and only to records that still belong here (a
      # company can be transferred to another organization).
      # Links to an invoice customer count only for customers in the book the
      # report reads fees from; any other is treated as not linked.
      @client_links = WorkHourClientLink.active.where(organization_id: @organization.id).includes(:invoice_recipient)
                                        .where("company_id IS NULL OR company_id IN (?)", eligible_companies.select(:id))
                                        .where("invoice_recipient_id IS NULL OR invoice_recipient_id IN (?)",
                                               InvoiceRecipient.where(organization_id: @organization.id, finance_book_id: finance_book&.id).select(:id))
                                        .index_by(&:tax_client_id)
      @staff_links = WorkHourStaffLink.active.where(organization_id: @organization.id).includes(:employee)
                                      .select { |link| link.disposition == "no_payroll" || link.employee&.company_id == @practice_company&.id }
                                      .index_by(&:tax_user_id)

      buckets = {}
      hours = Hash.new { |hash, key| hash[key] = new_hours }
      @rows.each do |row|
        bucket = bucket_for(row)
        buckets[bucket.key] ||= bucket
        add_hours(hours[[ bucket.key, row.tax_user_id ]], row)
      end

      costs = allocate_costs(hours)
      fees = fee_rows
      fees.each_key do |key|
        next if key.nil? || buckets.key?(key)

        kind, id = key.split(":")
        buckets[key] = kind == "company" ? Bucket.new(key: key, kind: "company", company_id: id.to_i) : Bucket.new(key: key, kind: "recipient", invoice_recipient_id: id.to_i)
      end
      name_clients(buckets.values)

      lines = buckets.values.map { |bucket| line_for(bucket, hours, costs, fees) }
      overhead_spread = spread_overhead!(lines)

      clients = lines.select { |line| CLIENT_KINDS.include?(line[:kind]) }.sort_by { |line| line[:name].downcase }
      overhead = lines.find { |line| line[:kind] == "overhead" }
      unassigned = lines.select { |line| %w[unlinked_client no_client].include?(line[:kind]) }
                        .sort_by { |line| [ line[:kind] == "no_client" ? 1 : 0, line[:name].downcase ] }
      unlinked_fees = fees[nil] || { amount: ZERO, tax_prep_amount: ZERO }
      unallocated = @unallocated_costs

      {
        period: @period.as_json,
        options: { cost_pending: @cost_pending, spread_overhead: @spread_overhead, cost_basis: cost_basis },
        cost_basis: cost_basis_summary,
        practice_company: @practice_company && { id: @practice_company.id, name: @practice_company.name },
        finance_book: finance_book && { id: finance_book.id, name: finance_book.name },
        coverage: coverage,
        clients: clients.map { |line| present(line) },
        overhead: overhead && present(overhead).merge(spread: overhead_spread),
        unassigned: unassigned.map { |line| present(line) },
        unlinked_fees: { fees: money(unlinked_fees[:amount]), tax_prep_fees: money(unlinked_fees[:tax_prep_amount]) },
        unallocated_costs: unallocated.map { |entry| entry.merge(cost: money(entry[:cost])) },
        # Shown for reference only: the Annual Payroll Summary leaves these
        # imported paychecks out, so they are not in any total or allocation.
        imported_pay_not_linked: { paycheck_count: @excluded_unlinked[:paycheck_count], cost: money(@excluded_unlinked[:total_payroll_cost]) },
        staff: staff_summary(hours),
        totals: totals(lines, unlinked_fees, unallocated)
      }
    end

    private

    def finance_book
      @finance_book ||= @settings.effective_finance_book
    end

    def new_hours
      { counted: ZERO, approved: ZERO, pending: ZERO, detail: Hash.new { |hash, key| hash[key] = { approved: ZERO, pending: ZERO } } }
    end

    def add_hours(entry, row)
      kind = row.pending? ? :pending : :approved
      entry[kind] += row.hours.to_d
      entry[:counted] += row.hours.to_d if kind == :approved || @cost_pending
      entry[:detail][[ row.category || "No category", row.task ]][kind] += row.hours.to_d
    end

    def bucket_for(row)
      return Bucket.new(key: "no_client", kind: "no_client", name: "No client chosen in Tax") if row.unassigned

      link = @client_links[row.tax_client_id]
      if link&.disposition == "company"
        Bucket.new(key: "company:#{link.company_id}", kind: "company", company_id: link.company_id)
      elsif link&.disposition == "recipient"
        recipient_bucket(link)
      elsif link&.disposition == "internal" || row.internal?
        Bucket.new(key: "overhead", kind: "overhead", name: "Internal / overhead")
      else
        Bucket.new(key: "tax_client:#{row.tax_client_id}", kind: "unlinked_client", tax_client_id: row.tax_client_id,
                   name: row.client_name)
      end
    end

    def name_clients(buckets)
      company_names = Company.where(id: buckets.filter_map(&:company_id)).pluck(:id, :name).to_h
      recipient_names = InvoiceRecipient.where(id: buckets.filter_map(&:invoice_recipient_id)).pluck(:id, :name).to_h
      buckets.each do |bucket|
        bucket.name = company_names[bucket.company_id] || "Client ##{bucket.company_id}" if bucket.kind == "company"
        bucket.name = recipient_names[bucket.invoice_recipient_id] || "Customer ##{bucket.invoice_recipient_id}" if bucket.kind == "recipient"
      end
    end

    # Employee payroll cost for the period, keyed by employee id (nil for
    # imported adjustments whose paycheck has no employee).
    def employee_costs
      @employee_costs ||= begin
        @excluded_unlinked = { paycheck_count: 0, total_payroll_cost: ZERO }
        @pay_date_total = ZERO
        if @practice_company
          summary = AnnualPayrollSummary.new(company: @practice_company)
          result = nil
          # Both totals come from one snapshot, so the difference shown next
          # to the Annual Payroll Summary can't straddle a payroll change made
          # between the two reads (same pattern as the cloners).
          options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }
          ApplicationRecord.transaction(**options) do
            result = summary.payroll_cost_by_employee(reporting_period, basis: cost_basis)
            @pay_date_total = if cost_basis == "pay_date"
              result[:total_payroll_cost]
            else
              summary.payroll_cost_by_employee(reporting_period)[:total_payroll_cost]
            end
          end
          @excluded_unlinked = result[:excluded_unlinked]
          result[:by_employee]
        else
          {}
        end
      end
    end

    def reporting_period
      PayrollReportingPeriod.new(start_date: @period.start_date, end_date: @period.end_date)
    end

    def cost_basis
      @requested_cost_basis || @settings.cost_basis.presence || "pay_date"
    end

    # How pay was dated, and how this total compares with the Annual Payroll
    # Summary's total payroll cost for paychecks paid in the same months.
    def cost_basis_summary
      reported = employee_costs.values.sum(ZERO) { |cost| cost[:total] }
      {
        basis: cost_basis,
        cost: money(reported),
        annual_payroll_summary_cost: money(@pay_date_total),
        difference: money(reported - @pay_date_total)
      }
    end

    # Returns { [bucket_key, tax_user_id] => cost } and records costs that
    # could not be placed on any hours.
    def allocate_costs(hours)
      @unallocated_costs = []
      allocated = Hash.new(ZERO)
      tax_users_by_employee = Hash.new { |hash, key| hash[key] = [] }
      @staff_links.each_value do |link|
        tax_users_by_employee[link.employee_id] << link.tax_user_id if link.disposition == "employee"
      end

      employee_costs.each do |employee_id, cost|
        next if cost[:total].zero?

        if employee_id.nil?
          @unallocated_costs << { employee_id: nil, name: "Adjustments to imported pay not linked to an employee",
                                  reason: "unlinked_adjustments", cost: cost[:total] }
          next
        end

        tax_user_ids = tax_users_by_employee[employee_id]
        weights = hours.select { |(_bucket, tax_user_id), _entry| tax_user_ids.include?(tax_user_id) }
                       .transform_values { |entry| entry[:counted] }
        parts = Allocation.split(cost[:total], weights)
        if parts.empty?
          reason = tax_user_ids.empty? ? "not_linked" : "no_hours"
          @unallocated_costs << { employee_id: employee_id, name: employee_name(employee_id), reason: reason, cost: cost[:total] }
        else
          parts.each { |key, amount| allocated[key] += amount }
        end
      end
      allocated
    end

    def employee_name(employee_id)
      @employee_names ||= Employee.where(id: employee_costs.keys.compact).to_h { |employee| [ employee.id, employee.full_name ] }
      @employee_names[employee_id] || "Employee ##{employee_id}"
    end

    # A link to an invoice customer is that customer's row, unless the
    # customer has since been given a Payroll client: then it counts as that
    # client, like a company link would.
    def recipient_bucket(link)
      company_id = recipient_company_id(link.invoice_recipient)
      if company_id
        Bucket.new(key: "company:#{company_id}", kind: "company", company_id: company_id)
      else
        Bucket.new(key: "recipient:#{link.invoice_recipient_id}", kind: "recipient", invoice_recipient_id: link.invoice_recipient_id)
      end
    end

    # Only live clients carry payroll cost, mappings or fees. A stored link or
    # setting that points at a demo or practice copy is ignored at read time.
    def eligible_companies
      Company.where(organization_id: @organization.id).live_payroll
    end

    def recipient_company_id(recipient)
      company_id = recipient&.company_id
      company_id if company_id && eligible_companies.where(id: company_id).exists?
    end

    # Fees keyed by report line. Every invoice lands on exactly one key:
    # - linked to a Payroll client: "company:ID";
    # - no Payroll client, and its customer has an explicit link here: that
    #   link's line ("recipient:ID", or "company:ID" once the customer has a
    #   Payroll client);
    # - no Payroll client, its customer has since been given one, and a Tax
    #   client is linked to that Payroll client: "company:ID" (so earlier
    #   company-less invoices follow the customer when its link is moved);
    # - otherwise nil ("Fees not linked to a client"). Nothing is inferred
    #   from names.
    def fee_rows
      return {} unless finance_book

      recipient_keys = @client_links.values.select { |link| link.disposition == "recipient" }
                                    .to_h { |link| [ link.invoice_recipient_id, recipient_bucket(link).key ] }
      linked_companies = @client_links.values.filter_map { |link| link.company_id if link.disposition == "company" }.to_set
      rows = InvoiceServiceFeeRevenue.call(finance_book: finance_book, service_month_from: @period.start_date,
                                           service_month_through: @period.end_date,
                                           tax_prep_service_names: @settings.tax_prep_service_names, by_recipient: true)
      recipient_companies = InvoiceRecipient.where(id: rows.filter_map { |row| row[:invoice_recipient_id] }).pluck(:id, :company_id).to_h
      # Fees billed to a non-live company (a stale demo or practice-copy link)
      # are firm noise, not client revenue: they never reach a line or total.
      workspace_ids = Company.test_workspace.where(id: rows.filter_map { |row| row[:company_id] } + recipient_companies.values.compact).pluck(:id).to_set
      rows.each_with_object({}) do |row, totals|
        next if workspace_ids.include?(row[:company_id]) || workspace_ids.include?(recipient_companies[row[:invoice_recipient_id]])

        key = if row[:company_id]
          "company:#{row[:company_id]}"
        elsif recipient_keys.key?(row[:invoice_recipient_id])
          recipient_keys[row[:invoice_recipient_id]]
        elsif (company_id = recipient_companies[row[:invoice_recipient_id]]) && linked_companies.include?(company_id)
          "company:#{company_id}"
        end
        entry = totals[key] ||= { amount: ZERO, tax_prep_amount: ZERO }
        entry[:amount] += row[:amount]
        entry[:tax_prep_amount] += row[:tax_prep_amount].to_d
      end
    end

    def line_for(bucket, hours, costs, fees)
      people = hours.select { |(bucket_key, _tax_user_id), _entry| bucket_key == bucket.key }.map do |(_bucket_key, tax_user_id), entry|
        {
          tax_user_id: tax_user_id,
          name: person_name(tax_user_id),
          linked: @staff_links.key?(tax_user_id),
          hours: entry[:counted],
          approved_hours: entry[:approved],
          pending_hours: entry[:pending],
          cost: costs[[ bucket.key, tax_user_id ]],
          categories: entry[:detail].map do |(category, task), detail|
            { category: category, task: task, hours: hours_string(detail[:approved]), pending_hours: hours_string(detail[:pending]) }
          end.sort_by { |detail| [ -(detail[:hours].to_d + detail[:pending_hours].to_d), detail[:category].to_s, detail[:task].to_s ] }
        }
      end.sort_by { |person| [ -person[:hours], person[:name].downcase ] }
      fee = CLIENT_KINDS.include?(bucket.kind) ? fees[bucket.key] : nil

      {
        key: bucket.key,
        kind: bucket.kind,
        company_id: bucket.company_id,
        invoice_recipient_id: bucket.invoice_recipient_id,
        tax_client_id: bucket.tax_client_id,
        name: bucket.name,
        hours: people.sum(ZERO) { |person| person[:hours] },
        pending_hours: people.sum(ZERO) { |person| person[:pending_hours] },
        direct_cost: people.sum(ZERO) { |person| person[:cost] },
        overhead_cost: ZERO,
        fees: fee ? fee[:amount] : ZERO,
        tax_prep_fees: fee ? fee[:tax_prep_amount] : ZERO,
        people: people
      }
    end

    # Moves overhead cost onto clients in proportion to their counted hours.
    def spread_overhead!(lines)
      overhead = lines.find { |line| line[:kind] == "overhead" }
      return false unless @spread_overhead && overhead && overhead[:direct_cost].nonzero?

      clients = lines.select { |line| CLIENT_KINDS.include?(line[:kind]) }
      parts = Allocation.split(overhead[:direct_cost], clients.to_h { |line| [ line[:key], line[:hours] ] })
      return false if parts.empty?

      clients.each { |line| line[:overhead_cost] = parts.fetch(line[:key], ZERO) }
      true
    end

    def person_name(tax_user_id)
      link = @staff_links[tax_user_id]
      return link.employee.full_name if link&.employee

      email = @rows.find { |row| row.tax_user_id == tax_user_id }&.email
      email.presence || "Tax user ##{tax_user_id}"
    end

    def present(line)
      cost = line[:direct_cost] + line[:overhead_cost]
      margin = line[:fees] - cost
      {
        key: line[:key],
        kind: line[:kind],
        company_id: line[:company_id],
        invoice_recipient_id: line[:invoice_recipient_id],
        tax_client_id: line[:tax_client_id],
        name: line[:name],
        hours: hours_string(line[:hours]),
        pending_hours: hours_string(line[:pending_hours]),
        direct_cost: money(line[:direct_cost]),
        overhead_cost: money(line[:overhead_cost]),
        cost: money(cost),
        fees: money(line[:fees]),
        tax_prep_fees: money(line[:tax_prep_fees]),
        other_fees: money(line[:fees] - line[:tax_prep_fees]),
        margin: money(margin),
        margin_percent: line[:fees].positive? ? percent(margin / line[:fees]) : nil,
        # Fees per counted hour: $0.00 for work that wasn't billed, nil only
        # when there are no counted hours to divide by.
        effective_rate: line[:hours].positive? ? money(line[:fees] / line[:hours]) : nil,
        people: line[:people].map do |person|
          person.merge(hours: hours_string(person[:hours]), approved_hours: hours_string(person[:approved_hours]),
                       pending_hours: hours_string(person[:pending_hours]), cost: money(person[:cost]))
        end
      }
    end

    # One row per paid employee (however many Tax identities point at them),
    # and one row per Tax user who is not on payroll or not linked yet.
    def staff_summary(hours)
      groups = Hash.new { |hash, key| hash[key] = { counted: ZERO, pending: ZERO, tax_user_ids: [] } }
      hours.each do |(_bucket, tax_user_id), entry|
        link = @staff_links[tax_user_id]
        key = link&.disposition == "employee" ? [ :employee, link.employee_id ] : [ :tax_user, tax_user_id ]
        group = groups[key]
        group[:counted] += entry[:counted]
        group[:pending] += entry[:pending]
        group[:tax_user_ids] |= [ tax_user_id ]
      end

      groups.map do |(kind, id), entry|
        link = kind == :employee ? @staff_links[entry[:tax_user_ids].first] : @staff_links[id]
        status = link ? link.disposition : "not_linked"
        cost = kind == :employee ? employee_costs.fetch(id, nil) : nil
        per_hour = cost && entry[:counted].positive? ? cost[:total] / entry[:counted] : nil
        {
          key: "#{kind}:#{id}",
          tax_user_ids: entry[:tax_user_ids].sort,
          name: kind == :employee ? link.employee.full_name : person_name(id),
          status: status,
          hours: hours_string(entry[:counted]),
          pending_hours: hours_string(entry[:pending]),
          pay: cost && money(cost[:pay]),
          employer_taxes: cost && money(cost[:employer_taxes]),
          employer_contributions: cost && money(cost[:employer_contributions]),
          cost: cost ? money(cost[:total]) : (kind == :employee ? money(ZERO) : nil),
          cost_per_hour: per_hour && money(per_hour)
        }
      end.sort_by { |person| person[:name].downcase }
    end

    def totals(lines, unlinked_fees, unallocated)
      hours = lines.sum(ZERO) { |line| line[:hours] }
      pending = lines.sum(ZERO) { |line| line[:pending_hours] }
      # Overhead moved onto clients is the same money, so count direct cost only.
      cost = lines.sum(ZERO) { |line| line[:direct_cost] } + unallocated.sum(ZERO) { |entry| entry[:cost] }
      fees = lines.sum(ZERO) { |line| line[:fees] } + unlinked_fees[:amount]
      tax_prep = lines.sum(ZERO) { |line| line[:tax_prep_fees] } + unlinked_fees[:tax_prep_amount]
      margin = fees - cost
      {
        hours: hours_string(hours),
        pending_hours: hours_string(pending),
        cost: money(cost),
        fees: money(fees),
        tax_prep_fees: money(tax_prep),
        other_fees: money(fees - tax_prep),
        margin: money(margin),
        margin_percent: fees.positive? ? percent(margin / fees) : nil,
        effective_rate: hours.positive? ? money(fees / hours) : nil
      }
    end

    # Which months in the period have been pulled from Tax, and how fresh.
    def coverage
      imports = WorkHourImport.succeeded.where(organization_id: @organization.id)
                              .where("range_start <= ? AND range_end >= ?", @period.end_date, @period.start_date)
                              .pluck(:range_start, :range_end, :finished_at)
      covered = Set.new
      imports.each do |first, last, _finished_at|
        ([ first, @period.start_date ].max..[ last, @period.end_date ].min).each { |date| covered << date }
      end
      missing = @period.months.reject { |month| (month..month.end_of_month).all? { |date| covered.include?(date) } }
      {
        missing_months: missing.map { |month| month.strftime("%Y-%m") },
        missing_month_labels: missing.map { |month| month.strftime("%B %Y") },
        last_refreshed_at: imports.filter_map(&:last).max&.iso8601,
        pending_hours: hours_string(@rows.select(&:pending?).sum(ZERO) { |row| row.hours.to_d })
      }
    end

    def money(value)
      decimal_string(value.to_d.round(2, :half_up), 2)
    end

    def hours_string(value)
      decimal_string(value.to_d.round(2, :half_up), 2)
    end

    def percent(ratio)
      decimal_string((ratio * 100).round(1, :half_up), 1)
    end

    # Exact decimal text (no float conversion) with a fixed number of places.
    def decimal_string(value, places)
      sign = value.negative? ? "-" : ""
      units, fraction = value.abs.to_s("F").split(".")
      "#{sign}#{units}.#{fraction.to_s.ljust(places, '0')[0, places]}"
    end
  end
end
