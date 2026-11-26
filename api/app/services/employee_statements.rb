# frozen_string_literal: true

# What one employee link may see in the employee app's Pay screens: frozen pay
# stubs posted to employee_documents, then the earlier QuickBooks checks for
# the same year (M4-4, D6, D7). AIRE keeps its own EmployeePayStatements
# reads; this class only borrows that presenter.
#
# A paper check void retains the pay and YTD. Financial reversals and
# rollbacks display only a withdrawal notice. Former access remains bounded
# by the last authorized pay date.
class EmployeeStatements
  PAGE_SIZE = 20
  # Revision chains are short (a void and a reissue, a check number change).
  # The bound keeps a malformed chain from looping.
  MAX_CHAIN = 25
  QUICKBOOKS_ID = /\Aqb-([1-9]\d{0,18})\z/
  DOCUMENT_ID = /\A[1-9]\d{0,18}\z/
  ITEM_ASSOCIATIONS = (EmployeePayStatements::LIST_ASSOCIATIONS + [ :employee ]).freeze
  # The detail view's rows, preloaded as EmployeePayStatements#find does.
  DETAIL_ASSOCIATIONS = ((EmployeePayStatements::LIST_ASSOCIATIONS - [ :pay_period ]) + [
    :payroll_item_earnings, :payroll_item_field_entries,
    { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company }
  ]).freeze

  Page = Struct.new(:statements, :years, :next_page, keyword_init: true)
  # kind: :payroll (document is the posted revision) or :quickbooks (check,
  # with document the posted original PDF when there is one).
  Statement = Struct.new(:kind, :document, :check, keyword_init: true) do
    def withdrawn?
      kind == :payroll && (document.payroll_item.pay_period.voided? || document.payroll_item.payroll_reversed_at.present?)
    end

    def id
      kind == :quickbooks ? "qb-#{check.id}" : document.id.to_s
    end
  end

  def initialize(link: nil, context: link)
    @company_id = context.company_id
    @employee_id = context.employee_id
    # A former link without an end date isn't eligible (portal_eligible), so
    # it never gets here; an impossible one still sees nothing.
    @access_until = (context.former_access_until&.in_time_zone(PayrollBusinessClock::TIME_ZONE)&.to_date || Date.new(1900) if context.former?)
  end

  def page(year: nil, page: 1)
    rows = ordered_union(year: year).limit(PAGE_SIZE + 1).offset((page - 1) * PAGE_SIZE)
      .pluck(Arel.sql("statements.source"), Arel.sql("statements.row_id"))
    statements = load_statements(rows.first(PAGE_SIZE))
    Page.new(statements: statements, years: years, next_page: (page + 1 if rows.size > PAGE_SIZE))
  end

  # The newest listed statement's pay date, or nil when none are posted yet.
  def latest_pay_date
    ordered_union(include_withdrawn: false).limit(1).pick(Arel.sql("statements.pay_date"))&.to_date
  end

  # A replaced revision's id finds the statement that replaced it, so an old
  # link opens the current version. Anything else not listed is nil.
  def find(id)
    if (match = QUICKBOOKS_ID.match(id.to_s))
      check = quickbooks_checks.find_by(id: match[1].to_i)
      return Statement.new(kind: :quickbooks, check: check, document: original_pdfs([ check.id ])[check.id]) if check
    elsif DOCUMENT_ID.match?(id.to_s)
      document = visible_document(id.to_i)
      document = current_successor(document) if document&.replaced?
      return load_statements([ [ "payroll", document.id ] ], detail: true).first if document && display_documents.exists?(id: document.id)
    end
    nil
  end

  # The frozen file to serve for an id: a listed statement's current PDF, an
  # earlier revision of a listed statement, or a QuickBooks original.
  def pdf_document(id)
    if QUICKBOOKS_ID.match?(id.to_s)
      return find(id)&.document
    end
    return unless DOCUMENT_ID.match?(id.to_s)

    document = visible_document(id.to_i)
    return unless document
    return document if document.posted? && !document.payroll_item.voided? && listed_documents.exists?(id: document.id)

    successor = current_successor(document) if document.replaced?
    document if successor && !successor.payroll_item.voided? && listed_documents.exists?(id: successor.id)
  end

  # Earlier revisions this posted document replaced, newest first. A delta
  # correction is a separate payment that points at the check it corrects;
  # that check is never an earlier version of the delta (it's listed on its
  # own while it stands, and a void+redo replaces it, not the delta), so the
  # chain stops at a delta's link to a different payroll item.
  def earlier_versions(document)
    versions = []
    current = document
    MAX_CHAIN.times do
      previous = current.replaces_document_id && visible_document(current.replaces_document_id)
      break unless previous&.replaced?
      break if delta_link?(current, previous)

      versions << previous
      current = previous
    end
    versions
  end

  # The regular payroll check listed before this one, across years, for "vs
  # last check". Nil when there is none.
  def previous_regular(document)
    item = document.payroll_item
    period = item.pay_period
    return unless period.run_purpose == "regular"

    previous = listed_documents.where(pay_periods: { run_purpose: "regular" })
      .where("(pay_periods.pay_date, pay_periods.id, payroll_items.id, employee_documents.id) < (?, ?, ?, ?)",
        period.pay_date, period.id, item.id, document.id)
      .order(*PAYROLL_ORDER).first
    load_statements([ [ "payroll", previous.id ] ]).first if previous
  end

  # previous_regular for a whole page, keyed by statement id. A page is a
  # contiguous slice of the full order (a year filter keeps it contiguous),
  # so each regular check's previous one is the next regular check on the
  # page; only the page's last regular check needs a query.
  def previous_regular_by_id(statements)
    regular = statements.select { |statement| statement.kind == :payroll && !statement.withdrawn? && regular?(statement.document) }
    found = regular.each_cons(2).to_h { |current, previous| [ current.id, previous ] }
    if (last = regular.last) && (previous = previous_regular(last.document))
      found[last.id] = previous
    end
    found
  end

  private

  def regular?(document)
    document.payroll_item.pay_period.run_purpose == "regular"
  end

  # True when current is a delta check whose link points at another payroll
  # item's document (the check it corrects).
  def delta_link?(current, previous)
    current.payroll_item_id != previous.payroll_item_id && current.payroll_item.correction_entry?
  end

  PAYROLL_ORDER = [
    Arel.sql("pay_periods.pay_date DESC"), Arel.sql("pay_periods.id DESC"),
    Arel.sql("payroll_items.id DESC"), Arel.sql("employee_documents.id DESC")
  ].freeze

  # Posted pay stubs whose payroll still stands, for this employee only.
  def listed_documents
    employee_documents.where(payroll_items: { payroll_reversed_at: nil })
      .where("employee_documents.status = 'posted' OR (employee_documents.status = 'withdrawn' AND employee_documents.withdrawal_reason = 'void' AND payroll_items.voided = TRUE)")
      .where(pay_periods: { company_id: @company_id, status: "committed", correction_status: [ nil, "correction" ] })
      .where(payroll_item_id: PayrollItem.reportable.where(company_id: @company_id, employee_id: @employee_id).select(:id))
  end

  def employee_documents
    scope = EmployeeDocument.joins(payroll_item: :pay_period)
      .where(company_id: @company_id, payroll_items: { company_id: @company_id, employee_id: @employee_id })
    @access_until ? scope.where(pay_periods: { pay_date: ..@access_until }) : scope
  end

  def display_documents
    withdrawn = employee_documents.where(status: %w[posted withdrawn])
      .where("pay_periods.correction_status = 'voided' OR payroll_items.payroll_reversed_at IS NOT NULL")
    listed_documents.or(withdrawn)
  end

  # Memoized: the scope's cutover date is a query of its own.
  def quickbooks_checks
    @quickbooks_checks ||= begin
      scope = EmployeeDocuments::QuickbooksHistory.scope(@company_id).where(employee_id: @employee_id)
      @access_until ? scope.where(pay_date: ..@access_until) : scope
    end
  end

  # Any of this employee's pay stub documents in this company, whatever their
  # status; the callers decide what may be shown.
  def visible_document(id)
    EmployeeDocument.joins(:payroll_item)
      .where(company_id: @company_id, payroll_items: { company_id: @company_id, employee_id: @employee_id })
      .find_by(id: id)
  end

  # The newest revision that replaced this one, following the chain forward.
  # A later revision of the same payroll item, or a check on another item
  # that isn't a delta correction (a void+redo replacement), replaces it. A
  # delta check also points at the check it corrects, but it's a separate
  # payment, never that check's replacement.
  def current_successor(document)
    current = document
    MAX_CHAIN.times do
      return current unless current.replaced?

      successor = EmployeeDocument.joins(:payroll_item)
        .where(company_id: @company_id, replaces_document_id: current.id,
          payroll_items: { company_id: @company_id, employee_id: @employee_id })
        .where("payroll_items.correction_for_payroll_item_id IS NULL OR employee_documents.payroll_item_id = ?",
          current.payroll_item_id)
        .where.not(status: "withdrawn")
        .order(revision: :desc, id: :desc).first
      return unless successor

      current = successor
    end
    nil
  end

  # One ordered list across both sources, paged in SQL. Payroll checks sort
  # before QuickBooks checks on the same day; QuickBooks history always ends
  # before the first Payroll run, so that only matters for odd data.
  def ordered_union(year: nil, include_withdrawn: true)
    payroll = include_withdrawn ? display_documents : listed_documents
    quickbooks = quickbooks_checks
    if year
      range = Date.new(year)..Date.new(year, 12, 31)
      payroll = payroll.where(pay_periods: { pay_date: range })
      quickbooks = quickbooks.where(pay_date: range)
    end
    union = union_all(
      payroll.select(Arel.sql("'payroll' AS source, 0 AS source_rank, employee_documents.id AS row_id, " \
        "pay_periods.pay_date AS pay_date, pay_periods.id AS sort_a, payroll_items.id AS sort_b")),
      quickbooks.select(Arel.sql("'quickbooks' AS source, 1 AS source_rank, historical_paychecks.id AS row_id, " \
        "historical_paychecks.pay_date AS pay_date, historical_paychecks.id AS sort_a, 0 AS sort_b")),
      "statements"
    )
    EmployeeDocument.unscoped.from(union).order(Arel.sql(
      "statements.pay_date DESC, statements.source_rank ASC, statements.sort_a DESC, statements.sort_b DESC, statements.row_id DESC"
    ))
  end

  def years
    union = union_all(
      display_documents.select(Arel.sql("pay_periods.pay_date AS pay_date")),
      quickbooks_checks.select(Arel.sql("historical_paychecks.pay_date AS pay_date")),
      "dates"
    )
    year = Arel.sql("EXTRACT(YEAR FROM dates.pay_date)::integer")
    EmployeeDocument.unscoped.from(union).distinct.order(Arel.sql("1 DESC")).pluck(year).map(&:to_i)
  end

  def union_all(left, right, name)
    Arel::Nodes::TableAlias.new(Arel::Nodes::UnionAll.new(left.arel, right.arel), name)
  end

  # Rows are [source, id] pairs in list order.
  def load_statements(rows, detail: false)
    document_ids = rows.filter_map { |source, id| id.to_i if source == "payroll" }
    check_ids = rows.filter_map { |source, id| id.to_i if source == "quickbooks" }
    documents = document_ids.empty? ? {} : EmployeeDocument.where(company_id: @company_id, id: document_ids)
      .includes(payroll_item: detail ? DETAIL_ASSOCIATIONS : ITEM_ASSOCIATIONS).order(:id).index_by(&:id)
    checks = check_ids.empty? ? {} : quickbooks_checks.where(id: check_ids).includes(:historical_paycheck_adjustments).order(:id).index_by(&:id)
    pdfs = original_pdfs(check_ids)

    rows.filter_map do |source, id|
      if source == "payroll"
        document = documents[id.to_i]
        Statement.new(kind: :payroll, document: document) if document
      elsif (check = checks[id.to_i])
        Statement.new(kind: :quickbooks, check: check, document: pdfs[check.id])
      end
    end
  end

  # The posted original QuickBooks stub for each check, newest revision.
  def original_pdfs(check_ids)
    return {} if check_ids.empty?

    EmployeeDocument.posted.where(company_id: @company_id, historical_paycheck_id: check_ids)
      .order(historical_paycheck_id: :asc, revision: :desc, id: :desc)
      .each_with_object({}) { |document, found| found[document.historical_paycheck_id] ||= document }
  end
end
