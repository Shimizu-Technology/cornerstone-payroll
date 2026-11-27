# frozen_string_literal: true

# Official W-2GU copies filled onto the IRS 2026 Form W-2GU. The IRS says the
# black copies "may be downloaded, completed, printed, and used"; Copy A (red,
# for SSA) is never produced because W-2s are e-filed.
#
#   employee: one sheet per employee, sorted by last name. The front is Copy B
#             over Copy C; the back is the IRS Notice and Instructions that
#             print behind those copies, so a double-sided print (flip on the
#             long edge) matches the IRS form. The SSN prints as XXX-XX-1234.
#   drt:      Copy 1 for the Guam Department of Revenue and Taxation, two
#             employees a page, with the full SSN DRT requires. It is also the
#             employer's paper record.
#
# Box values come straight from W2GuAggregator rows. Boxes the app does not
# model (8, 10, 11, 14a and the control number) stay blank. Nothing is cut
# short: a value that won't print whole, even at the smallest font size,
# refuses the whole download with a list of what to shorten.
class W2GuOfficialCopies < OfficialPdfOverlay
  # One line per value to fix, naming the person and the box.
  class DoesNotFit < ArgumentError
    attr_reader :problems

    def initialize(problems)
      @problems = problems
      super("These W-2GU copies can't be made until #{problems.one? ? 'this is' : 'these are'} fixed:\n" +
        problems.map { |problem| "• #{problem}" }.join("\n"))
    end
  end

  TEMPLATE_PATH = Rails.root.join("lib/assets/irs_form_w2gu_2026.pdf")
  SUPPORTED_TAX_YEARS = [ 2026 ].freeze
  KINDS = %w[employee drt].freeze
  PAGE_SIZE = [ 612.0, 792.0 ].freeze
  # Each template page holds two forms; the bottom one sits exactly half a
  # page below the top one.
  HALF_PAGE = 396.0
  TEXT_LIFT = 1.5

  # Zero-based template pages.
  COPY_1 = 2
  COPY_B = 3
  COPY_B_BACK = 4
  COPY_C = 5
  COPY_C_BACK = 6

  # Field rectangles of the top form, from the template's own (unused) form
  # widgets, as [left, bottom, right, top] in points.
  FIELDS = {
    ssn: [ 153.2, 732.0, 278.8, 744.0 ],
    ein: [ 38.0, 708.0, 330.2, 720.0 ],
    employer: [ 38.0, 636.0, 330.2, 696.0 ],
    first_name: [ 38.0, 588.0, 171.8, 600.0 ],
    last_name: [ 173.8, 588.0, 308.6, 600.0 ],
    suffix: [ 310.6, 588.0, 330.2, 600.0 ],
    employee_address: [ 38.0, 528.0, 330.2, 586.0 ],
    box1: [ 333.2, 708.0, 451.6, 720.0 ],
    box2: [ 455.6, 708.0, 574.0, 720.0 ],
    box3: [ 332.2, 684.0, 452.6, 696.0 ],
    box4: [ 454.6, 684.0, 574.0, 696.0 ],
    box5: [ 332.2, 660.0, 452.6, 672.0 ],
    box6: [ 454.6, 660.0, 574.0, 672.0 ],
    box7: [ 332.2, 636.0, 452.6, 648.0 ],
    box13_retirement_plan: [ 384.6, 577.7, 394.6, 587.7 ],
    box14b: [ [ 332.2, 516.0, 391.4, 528.0 ], [ 393.4, 516.0, 452.6, 528.0 ] ]
  }.freeze
  BOX12 = [
    [ [ 462.8, 588.0, 488.6, 600.0 ], [ 490.6, 588.0, 574.0, 600.0 ] ],
    [ [ 462.8, 564.0, 488.6, 576.0 ], [ 490.6, 564.0, 574.0, 576.0 ] ],
    [ [ 462.8, 540.0, 488.6, 552.0 ], [ 490.6, 540.0, 574.0, 552.0 ] ],
    [ [ 462.8, 516.0, 488.6, 528.0 ], [ 490.6, 516.0, 574.0, 528.0 ] ]
  ].freeze
  # The margin above the top form, for the sorting line.
  MARGIN_NOTE = [ 38.0, 758.0, 574.0, 770.0 ].freeze
  # The values that can run long: how each is drawn (lift 0 puts a block at
  # the top of its box), and the line that names it when it doesn't fit.
  TEXT_FIELDS = {
    first_name: { size: 9, problem: "the first name and middle initial are too long to fit Box e — shorten them on the employee's profile" },
    last_name: { size: 9, problem: "the last name is too long to fit Box e — shorten it on the employee's profile" },
    suffix: { size: 9, min_font_size: 6.5, problem: "the name suffix is too long to fit Box e's Suff. box" },
    employee_address: { lift: 0, size: 9, valign: :top, min_font_size: 6.5,
      problem: "the address is too long to fit Box f — shorten it on the employee's profile" }
  }.freeze
  EMPLOYER_TEXT = { lift: 0, size: 9, valign: :top, min_font_size: 6.5 }.freeze

  Sheet = Struct.new(:top, :bottom, :people, keyword_init: true)

  # Final (unwatermarked) copies need a ready mark on these exact inputs and
  # a W-2 filing decision that still allows filing-ready output.
  def self.final?(company:, year:, readiness:, fingerprint:)
    return false unless readiness&.current?(fingerprint)
    # The fingerprint already changes with one; this holds for any caller.
    return false if PayrollBridgeOverlap.new(company_id: company.id, year: year).w2_blocking.any?

    PayrollFilingResponsibilityGate.annual(company: company, tax_year: year).dig(:capabilities, :all_filing_ready_exports_allowed) == true
  end

  # The report, sign-off and filing decision a set of copies is drawn from,
  # shared by the staff download and the employee app's posting (M4-5).
  # final: unwatermarked copies are allowed (never in a practice copy; a demo
  # company prints like a live client). The callers hold the company lock,
  # which mark-ready and preflight take to change the sign-off.
  def self.snapshot(company, year)
    responsibility = company.payroll_filing_responsibilities.find_by(tax_year: year, quarter: nil, filing_type: "w2_gu")
    report = W2GuAggregator.new(company, year).generate if responsibility&.responsible_party == "cornerstone"
    fingerprint = W2FilingInputsFingerprint.new(company: company, year: year, report: report).call if report
    # Read after the fingerprint, so a sign-off change while it was computed is seen.
    readiness = W2FilingReadiness.find_by(company_id: company.id, year: year)
    {
      cornerstone_files: report.present?,
      report: report,
      readiness: readiness,
      fingerprint: fingerprint,
      # Covers what the fingerprint doesn't, such as the employer's name and
      # address and middle names.
      input_revision: YearEnd::InputRevision.for(company.id, year)[company.id],
      final: report.present? && !company.practice_copy? &&
        final?(company: company, year: year, readiness: readiness, fingerprint: fingerprint)
    }
  end

  # What must not change between a snapshot and the finished file.
  def self.snapshot_signature(snapshot)
    readiness = snapshot[:readiness]
    snapshot.slice(:cornerstone_files, :fingerprint, :input_revision, :final)
      .merge(readiness: readiness && [ readiness.status, readiness.ready_fingerprint ])
  end

  def self.supported_tax_year?(tax_year)
    SUPPORTED_TAX_YEARS.include?(tax_year.to_i)
  end

  def self.unsupported_message(tax_year)
    "Official W-2GU copies are available for tax year #{SUPPORTED_TAX_YEARS.to_sentence(last_word_connector: ' and ')} only. " \
      "For #{tax_year}, use the W-2GU report and the matching IRS form."
  end

  # report: unmodified W2GuAggregator output for company and its year.
  # practice: a test or practice workspace, whose copies are always drafts.
  # employee_id: one employee's Copy B and C only, for the employee app
  # (M4-5). That path makes final copies only; a draft is refused.
  def initialize(company:, report:, kind:, draft:, practice: false, employee_id: nil)
    raise ReportValidationError, "Unknown W-2GU copy: #{kind}" unless KINDS.include?(kind.to_s)

    @company = company
    @report = report.deep_symbolize_keys
    @kind = kind.to_s
    @practice = practice
    @draft = draft || practice
    @employee_id = employee_id
    raise TemplateUnavailableError, self.class.unsupported_message(year) unless self.class.supported_tax_year?(year)
    if employee_id
      raise ReportValidationError, "A single employee's W-2GU is only Copies B and C" unless @kind == "employee"
      raise ReportValidationError, "A single employee's W-2GU is made only when the W-2s are final" if @draft
      raise ReportValidationError, "No #{year} W-2 for that employee" if people.empty?
    end

    super(template_path: TEMPLATE_PATH, page_sizes: [ PAGE_SIZE ])
  end

  def generate
    raise ReportValidationError, "No employees have #{year} W-2 wages" if people.empty?

    check_fit!
    template = load_template!
    overlay = CombinePDF.parse(build_overlay_pdf(sheets.length))
    bases = {}
    output = CombinePDF.new
    sheets.each_with_index do |sheet, index|
      output << share(bases[[ sheet.top, sheet.bottom ]] ||= compose(template, sheet))
      output.pages[index] << overlay.pages[index]
    end
    output.to_pdf
  end

  def filename
    name = ActiveSupport::Inflector.transliterate(company.name.to_s).gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").first(40).presence || "Employer"
    label = kind == "drt" ? "Copy1_DRT" : "Employee_Copies_B_C"
    "W-2GU_#{year}_#{name}_#{label}#{'_DRAFT' if draft}.pdf"
  end

  def employee_count
    people.length
  end

  # Refuses (DoesNotFit) when any value wouldn't print whole, before any page
  # is drawn. The employee app's posting checks the whole report this way, so
  # it posts only what the staff download would print.
  def ensure_fits!
    check_fit!
  end

  private

  attr_reader :company, :report, :kind, :draft, :practice, :employee_id

  def year
    report.dig(:meta, :year).to_i
  end

  # Employees in last-name order, each with the aggregator's box values and
  # the name and address parts the form prints separately.
  def people
    @people ||= begin
      rows = Array(report[:employees]).index_by { |row| row[:employee_id] }
      rows = rows.slice(employee_id) if employee_id
      Employee.where(company_id: company.id, id: rows.keys).to_a
        .sort_by { |employee| [ employee.last_name.to_s.downcase, employee.first_name.to_s.downcase, employee.id ] }
        .map do |employee|
          [ employee.full_name, employee.address_line1, employee.address_line2, employee.city ].each do |value|
            PdfUnicodeFont.ensure_printable!(value, label: "Employee", cjk: false)
          end
          { employee: employee, row: rows.fetch(employee.id) }
        end
    end
  end

  def sheets
    @sheets ||= if kind == "drt"
      people.each_slice(2).map { |pair| Sheet.new(top: COPY_1, bottom: pair[1] ? COPY_1 : nil, people: pair) }
    else
      people.flat_map do |person|
        [
          Sheet.new(top: COPY_B, bottom: COPY_C, people: [ person, person ]),
          Sheet.new(top: COPY_B_BACK, bottom: COPY_C_BACK, people: [])
        ]
      end
    end
  end

  # Builds one sheet layout from the template's top and bottom halves. The
  # form widgets are dropped because values are painted into the page content.
  def compose(template, sheet)
    if sheet.top == sheet.bottom
      page = template.pages[sheet.top].copy
    else
      page = clip(template.pages[sheet.top].copy, bottom_half: false)
      page << clip(template.pages[sheet.bottom].copy, bottom_half: true) if sheet.bottom
    end
    page.delete(:Annots)
    page
  end

  # A new page drawing the layout's own content streams and resources, so a
  # client with hundreds of employees doesn't carry hundreds of copies of the
  # form. Only the page's content list is its own, for the overlay.
  def share(base)
    page = base.clone
    page[:Contents] = base[:Contents].dup
    page
  end

  def clip(page, bottom_half:)
    y = bottom_half ? 0 : HALF_PAGE
    page.send(:insert_content, "q 0 #{y} #{PAGE_SIZE[0]} #{HALF_PAGE} re W n", 0)
    page.send(:insert_content, "Q")
    page
  end

  def draw_page(pdf, page_number)
    sheet = sheets.fetch(page_number - 1)
    return if sheet.people.empty?

    draw_margin_note(pdf, sheet, page_number)
    sheet.people.each_with_index do |person, index|
      draw_form(pdf, person, index.zero? ? 0 : -HALF_PAGE)
    end
  end

  def draw_document_status(pdf, _page_number)
    DemoPdfFooter.draw_overlay_footer(pdf, company: company)
    return unless draft

    reason = practice ? "a practice copy" : "the #{year} W-2s are not marked ready"
    PdfPreviewWatermark.draw_page(pdf, label: "DRAFT", bands: 2,
      note: "DRAFT — #{reason}. Do not give to employees or file.")
  end

  # Measures every long value at its box's smallest font size before any
  # page is drawn, and lists each one that would be cut short. More Box 12
  # entries than the form holds also need a second W-2, which these copies
  # don't make.
  def check_fit!
    pdf = PdfUnicodeFont.document(cjk: false, page_size: PAGE_SIZE, margin: 0)
    pdf.font("Helvetica")
    problems = []
    unless text_fits?(pdf, FIELDS[:employer], employer_lines.join("\n"), **EMPLOYER_TEXT.except(:lift))
      problems << "The employer's name and address are too long to fit Box c — shorten them in the client's company settings."
    end
    people.each do |person|
      employee = person[:employee]
      TEXT_FIELDS.each do |field, options|
        next if text_fits?(pdf, FIELDS[field], field_text(employee, field), **options.except(:lift, :problem))

        problems << "#{employee.full_name}: #{options[:problem]}."
      end
      box12 = Array(person[:row][:box12]).length
      if box12 > BOX12.length
        problems << "#{employee.full_name}: #{box12} Box 12 entries, but one W-2 holds #{BOX12.length}. " \
                    "The IRS requires a second W-2 for the rest, which these copies can't print."
      end
    end
    raise DoesNotFit, problems if problems.any?
  end

  def draw_margin_note(pdf, sheet, page_number)
    note = if kind == "drt"
      "#{company.name} · #{year} W-2GU Copy 1 for Guam DRT · page #{page_number} of #{sheets.length}"
    else
      employee = sheet.people.first[:employee]
      position = (page_number + 1) / 2
      label = "#{employee.last_name}, #{employee.first_name} · #{company.name} · #{year} W-2GU"
      employee_id ? label : "#{label} · employee #{position} of #{people.length}"
    end
    pdf.fill_color "555555"
    pdf.text_box(note, at: [ MARGIN_NOTE[0], MARGIN_NOTE[3] ], width: MARGIN_NOTE[2] - MARGIN_NOTE[0],
      height: MARGIN_NOTE[3] - MARGIN_NOTE[1], size: 7.5, overflow: :shrink_to_fit, min_font_size: 6)
    pdf.fill_color "000000"
  end

  def draw_form(pdf, person, dy)
    employee = person[:employee]
    row = person[:row]
    # Single-line values sit a little above the widget rectangle, which
    # touches each box's bottom rule.
    at = ->(rect, lift = TEXT_LIFT) { [ rect[0], rect[1] + dy + lift, rect[2], rect[3] + dy + lift ] }

    draw_text_box(pdf, at.(FIELDS[:ssn]), ssn_for(employee, row), size: 10)
    draw_text_box(pdf, at.(FIELDS[:ein]), formatted_ein, size: 10)
    draw_text_box(pdf, at.(FIELDS[:employer], EMPLOYER_TEXT[:lift]), employer_lines.join("\n"), **EMPLOYER_TEXT.except(:lift))
    TEXT_FIELDS.each do |field, options|
      draw_text_box(pdf, at.(FIELDS[field], options.fetch(:lift, TEXT_LIFT)), field_text(employee, field), **options.except(:lift, :problem))
    end

    {
      box1: :box1_wages_tips_other_comp,
      box2: :box2_federal_income_tax_withheld,
      box3: :box3_social_security_wages,
      box4: :box4_social_security_tax_withheld,
      box5: :box5_medicare_wages_tips,
      box6: :box6_medicare_tax_withheld
    }.each { |box, key| draw_amount(pdf, at.(FIELDS[box]), row[key]) }
    draw_amount(pdf, at.(FIELDS[:box7]), row[:box7_social_security_tips]) if row[:box7_social_security_tips].to_d.positive?

    Array(row[:box12]).each_with_index do |entry, index|
      code_rect, amount_rect = BOX12[index]
      draw_text_box(pdf, at.(code_rect), entry[:code], size: 9, align: :center)
      draw_amount(pdf, at.(amount_rect), entry[:amount])
    end
    draw_checkbox(pdf, at.(FIELDS[:box13_retirement_plan], 0), row[:box13_retirement_plan])
    # The aggregator picks the two codes the IRS allows (keeping "000").
    Array(row[:box14b_tipped_occupation_codes]).first(FIELDS[:box14b].length).each_with_index do |code, index|
      draw_text_box(pdf, at.(FIELDS[:box14b][index]), code, size: 9, align: :center)
    end
  end

  # Kept clear of the right rule, which is heavy on Copy B's boxes 1 and 2.
  def draw_amount(pdf, rect, value)
    left, bottom, right, top = rect
    draw_text_box(pdf, [ left, bottom, right - 2, top ], money_string(value), size: 10, align: :right)
  end

  # Employee copies show only the last four digits; DRT's Copy 1 shows the
  # whole number. The full SSN is read only for Copy 1.
  def ssn_for(employee, row)
    if kind == "drt"
      digits = employee.ssn_digits
      digits&.length == 9 ? "#{digits[0, 3]}-#{digits[3, 2]}-#{digits[5, 4]}" : nil
    else
      last4 = row[:employee_ssn_last4].to_s
      last4.match?(/\A\d{4}\z/) ? "XXX-XX-#{last4}" : nil
    end
  end

  def formatted_ein
    digits = company.ein.to_s.gsub(/\D/, "")
    digits.length == 9 ? "#{digits[0, 2]}-#{digits[2, 7]}" : company.ein.to_s
  end

  def employer_lines
    @employer_lines ||= begin
      PdfUnicodeFont.ensure_printable!(company.name, label: "Employer", cjk: false)
      [ company.name, company.address_line1, company.address_line2, city_line(company) ].compact_blank
    end
  end

  def field_text(employee, field)
    case field
    when :first_name then first_name_and_initial(employee)
    when :last_name then employee.last_name
    when :suffix then employee.name_suffix
    when :employee_address then employee_address_lines(employee).join("\n")
    end
  end

  def first_name_and_initial(employee)
    initial = employee.middle_name.to_s.strip.first
    [ employee.first_name, ("#{initial}." if initial.present?) ].compact.join(" ")
  end

  def employee_address_lines(employee)
    [ employee.address_line1, employee.address_line2, city_line(employee) ].compact_blank
  end

  def city_line(record)
    city_state = [ record.city.presence, record.state.presence ].compact.join(", ")
    [ city_state.presence, record.zip.presence ].compact.join(" ")
  end
end
