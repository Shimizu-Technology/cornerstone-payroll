# frozen_string_literal: true

# Official 1099-NEC copies filled onto the IRS Form 1099-NEC (Rev. December
# 2026, `lib/assets/irs_form_1099nec_2026.pdf`). The IRS says its black
# copies may be downloaded and printed "to satisfy the requirement to
# furnish the information to the recipient". Copy A (red) is never produced:
# 1099s go to Guam DRT as an e-file.
#
# The template has one form per page and no Copy C. Its pages: 1 notice,
# 2 Copy A, 3 Copy 1 (state tax department), 4 Copy B (recipient), 5 the
# Instructions for Recipient (the back of Copy B), 6 Copy 2 (the recipient's
# state return).
#
#   recipient: one sheet per contractor, sorted by name. The front is Copy B,
#              the back the Instructions for Recipient, so a double-sided
#              print matches the IRS form. The payee's TIN prints truncated
#              (***-**-1234 or **-***1234), as the IRS allows on recipient
#              statements. The payer's TIN is never truncated.
#   payer:     the payer's record, one form a page on the Copy 1 page, with
#              full TINs. The template has no payer copy, and Copy 1 is the
#              copy for the tax department, which in Guam is DRT itself.
#
# Box 1a comes from Form1099NecAggregator: payroll plus one-off checks linked
# to the contractor. Box 4 is the income tax withheld from contractor pay,
# printed when there is any; a contractor with withholding gets a 1099 at
# any amount. The account number is the one the Pub 1220 e-file writes
# (Form1099Pub1220Generator.account_number), so paper and e-file match.
# Boxes 1b-1d, 2, 3 and 5-7 stay blank: the app does not track tips,
# overtime, direct sales or golden parachutes for contractors, and Guam has
# no separate state boxes. Nothing prints partly: a value that won't fit at
# the smallest font size refuses the whole download.
class Form1099NecOfficialCopies < OfficialPdfOverlay
  # One line per value to fix, naming the payee and the box.
  class DoesNotFit < ArgumentError
    attr_reader :problems

    def initialize(problems)
      @problems = problems
      super("These 1099-NEC copies can't be made until #{problems.one? ? 'this is' : 'these are'} fixed:\n" +
        problems.map { |problem| "• #{problem}" }.join("\n"))
    end
  end

  TEMPLATE_PATH = Rails.root.join("lib/assets/irs_form_1099nec_2026.pdf")
  SUPPORTED_TAX_YEARS = [ 2026 ].freeze
  KINDS = %w[recipient payer].freeze
  PAGE_SIZE = [ 612.0, 792.0 ].freeze
  TEXT_LIFT = 1.5

  # Zero-based template pages.
  COPY_1 = 2
  COPY_B = 3
  RECIPIENT_INSTRUCTIONS = 4

  # Field rectangles from the template's own (unused) form widgets, as
  # [left, bottom, right, top] in points. Every copy page uses the same ones.
  FIELDS = {
    calendar_year: [ 417.6, 687.0, 446.4, 696.0 ],
    payer_name: [ 52.4, 720.0, 294.2, 744.0 ],
    payer_street: [ 52.4, 696.0, 207.8, 708.0 ],
    payer_room: [ 209.8, 696.0, 294.2, 708.0 ],
    payer_city: [ 52.4, 672.0, 207.8, 684.0 ],
    payer_phone: [ 209.8, 672.0, 294.2, 684.0 ],
    payer_state: [ 52.4, 648.0, 171.8, 660.0 ],
    payer_zip: [ 209.8, 648.0, 294.2, 660.0 ],
    payer_tin: [ 52.4, 612.0, 171.8, 636.0 ],
    recipient_tin: [ 173.8, 612.0, 294.2, 636.0 ],
    recipient_name: [ 52.4, 576.0, 294.2, 600.0 ],
    recipient_street: [ 52.4, 552.0, 243.8, 564.0 ],
    recipient_apt: [ 245.8, 552.0, 294.2, 564.0 ],
    recipient_city: [ 52.4, 528.0, 294.2, 540.0 ],
    recipient_state: [ 52.4, 504.0, 171.8, 516.0 ],
    recipient_zip: [ 209.8, 504.0, 294.2, 516.0 ],
    account_number: [ 52.4, 432.0, 294.2, 456.0 ],
    box1a: [ 309.6, 648.0, 494.8, 660.0 ],
    box4: [ 309.6, 468.0, 494.8, 480.0 ]
  }.freeze
  # Below the form's footer line, for the sorting line.
  MARGIN_NOTE = [ 50.4, 392.0, 576.0, 414.0 ].freeze
  # How long values are drawn: a two-line name block sits at the top of its
  # box; everything else is one line that shrinks to its minimum size.
  BLOCK = { size: 9, valign: :top, min_font_size: 6.5 }.freeze
  LINE = { size: 9, min_font_size: 6 }.freeze

  Sheet = Struct.new(:page, :payee, keyword_init: true)

  def self.supported_tax_year?(tax_year)
    SUPPORTED_TAX_YEARS.include?(tax_year.to_i)
  end

  def self.unsupported_message(tax_year)
    "Official 1099-NEC copies are available for tax year #{SUPPORTED_TAX_YEARS.to_sentence(last_word_connector: ' and ')} only. " \
      "For #{tax_year}, use the 1099-NEC report and the matching IRS form."
  end

  # The payee's TIN as a recipient statement may show it: the last four
  # digits only.
  def self.truncated_tin(tin)
    return nil unless tin

    tin[:type] == "EIN" ? "**-***#{tin[:digits].last(4)}" : "***-**-#{tin[:digits].last(4)}"
  end

  def self.full_tin(tin)
    return nil unless tin

    digits = tin[:digits]
    tin[:type] == "EIN" ? "#{digits[0, 2]}-#{digits[2, 7]}" : "#{digits[0, 3]}-#{digits[3, 2]}-#{digits[5, 4]}"
  end

  # report: unmodified Form1099NecAggregator output for company and its year.
  # practice: a test or practice workspace, whose copies are always drafts.
  def initialize(company:, report:, kind:, draft:, practice: false)
    raise ArgumentError, "Unknown 1099-NEC copy: #{kind}" unless KINDS.include?(kind.to_s)

    @company = company
    @report = report.deep_symbolize_keys
    @kind = kind.to_s
    @practice = practice
    @draft = draft || practice
    raise TemplateUnavailableError, self.class.unsupported_message(year) unless self.class.supported_tax_year?(year)

    super(template_path: TEMPLATE_PATH, page_sizes: [ PAGE_SIZE ])
  end

  def generate
    raise ArgumentError, "No contractor gets a #{year} 1099-NEC" if payees.empty?

    check_fit!
    template = load_template!
    overlay = CombinePDF.parse(build_overlay_pdf(sheets.length))
    bases = {}
    output = CombinePDF.new
    sheets.each_with_index do |sheet, index|
      output << share(bases[sheet.page] ||= compose(template, sheet.page))
      output.pages[index] << overlay.pages[index]
    end
    output.to_pdf
  end

  # Everything that would stop the copies printing, one line each, without
  # drawing them. Mark 1099s ready refuses on the same list.
  def problems
    pdf = PdfUnicodeFont.document(cjk: false, page_size: PAGE_SIZE, margin: 0)
    pdf.font("Helvetica")
    found = []
    begin
      PdfUnicodeFont.ensure_printable!(company.name, label: "Payer", cjk: false)
      [ company.address_line1, company.address_line2, company.city ].each { |value| PdfUnicodeFont.ensure_printable!(value, label: "Payer", cjk: false) }
    rescue PdfUnicodeFont::UnprintableName => e
      found << e.message
    end
    found << "The client's name is too long to fit the payer's name box — shorten it in the client's company settings." unless text_fits?(pdf, FIELDS[:payer_name], company.name, **BLOCK)
    found << "The client's street address is too long to fit the payer's address box — shorten it in the client's company settings." unless address_parts(pdf, company, :payer_street, :payer_room)
    found << "The client's city is too long to fit the payer's city box — shorten it in the client's company settings." unless text_fits?(pdf, FIELDS[:payer_city], company.city, **LINE)
    found << "The client's phone number is too long to fit the payer's phone box — shorten it in the client's company settings." unless text_fits?(pdf, FIELDS[:payer_phone], company.phone, **LINE)
    payees.each do |payee|
      employee = payee[:employee]
      name = employee.full_name
      begin
        [ name, employee.business_name, employee.address_line1, employee.address_line2, employee.city ].each { |value| PdfUnicodeFont.ensure_printable!(value, label: "Contractor", cjk: false) }
      rescue PdfUnicodeFont::UnprintableName => e
        found << "#{name}: #{e.message}"
      end
      found << "#{name}: the name is too long to fit the recipient's name box — shorten it on the contractor's record." unless text_fits?(pdf, FIELDS[:recipient_name], recipient_name_lines(employee).join("\n"), **BLOCK)
      found << "#{name}: the street address is too long to fit the recipient's address box — shorten it on the contractor's record." unless address_parts(pdf, employee, :recipient_street, :recipient_apt)
      found << "#{name}: the city is too long to fit the recipient's city box — shorten it on the contractor's record." unless text_fits?(pdf, FIELDS[:recipient_city], employee.city, **LINE)
    end
    found
  end

  def filename
    name = ActiveSupport::Inflector.transliterate(company.name.to_s).gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").first(40).presence || "Payer"
    label = kind == "payer" ? "Payer_Record" : "Recipient_Copies_B"
    "1099-NEC_#{year}_#{name}_#{label}#{'_DRAFT' if draft}.pdf"
  end

  def payee_count
    payees.length
  end

  private

  attr_reader :company, :report, :kind, :draft, :practice

  def year
    report.dig(:meta, :year).to_i
  end

  # Contractors that get a 1099 (unlinked one-off payees have no TIN or
  # address and are never printed), sorted by the name the form shows.
  def payees
    @payees ||= begin
      rows = Array(report[:reportable_contractors]).select { |row| row[:employee_id] }.index_by { |row| row[:employee_id] }
      Employee.where(company_id: company.id, id: rows.keys).to_a
        .map { |employee| { employee: employee, row: rows.fetch(employee.id) } }
        .sort_by { |payee| sort_key(payee[:employee]) }
    end
  end

  def sort_key(employee)
    name = employee.business_contractor? && employee.business_name.present? ? employee.business_name : "#{employee.last_name} #{employee.first_name} #{employee.middle_name}"
    [ name.to_s.downcase.squish, employee.id ]
  end

  def sheets
    @sheets ||= if kind == "payer"
      payees.map { |payee| Sheet.new(page: COPY_1, payee: payee) }
    else
      payees.flat_map { |payee| [ Sheet.new(page: COPY_B, payee: payee), Sheet.new(page: RECIPIENT_INSTRUCTIONS, payee: nil) ] }
    end
  end

  # One template page without its form widgets, since values are painted
  # into the page content.
  def compose(template, page_index)
    page = template.pages[page_index].copy
    page.delete(:Annots)
    page
  end

  # A new page drawing the shared page's content streams and resources, so a
  # client with many contractors doesn't carry many copies of the form. Only
  # the page's content list is its own, for the overlay.
  def share(base)
    page = base.clone
    page[:Contents] = base[:Contents].dup
    page
  end

  def check_fit!
    found = problems
    raise DoesNotFit, found if found.any?
  end

  def draw_page(pdf, page_number)
    sheet = sheets.fetch(page_number - 1)
    return unless sheet.payee

    draw_margin_note(pdf, sheet, page_number)
    draw_form(pdf, sheet.payee)
  end

  def draw_document_status(pdf, _page_number)
    return unless draft

    reason = practice ? "a practice copy" : "the #{year} 1099s are not marked ready"
    PdfPreviewWatermark.draw_page(pdf, label: "DRAFT", bands: 2,
      note: "DRAFT — #{reason}. Do not give to contractors or file.")
  end

  def draw_margin_note(pdf, sheet, page_number)
    employee = sheet.payee[:employee]
    note = if kind == "payer"
      "Payer's record (the IRS Copy 1 page). Keep with your filing records; not mailed when you e-file with Guam DRT. · " \
        "#{company.name} · #{year} 1099-NEC · #{display_name(employee)} · form #{page_number} of #{sheets.length}"
    else
      position = (page_number + 1) / 2
      "#{display_name(employee)} · #{company.name} · #{year} 1099-NEC · contractor #{position} of #{payees.length}"
    end
    pdf.fill_color "555555"
    pdf.text_box(note, at: [ MARGIN_NOTE[0], MARGIN_NOTE[3] ], width: MARGIN_NOTE[2] - MARGIN_NOTE[0],
      height: MARGIN_NOTE[3] - MARGIN_NOTE[1], size: 7.5, overflow: :shrink_to_fit, min_font_size: 6)
    pdf.fill_color "000000"
  end

  def draw_form(pdf, payee)
    employee = payee[:employee]
    at = ->(rect, lift = TEXT_LIFT) { [ rect[0], rect[1] + lift, rect[2], rect[3] + lift ] }

    draw_text_box(pdf, at.(FIELDS[:calendar_year], 0), year.to_s, size: 8, align: :center)
    draw_text_box(pdf, at.(FIELDS[:payer_name], 0), company.name, **BLOCK)
    street, room = address_parts(pdf, company, :payer_street, :payer_room)
    draw_text_box(pdf, at.(FIELDS[:payer_street]), street, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_room]), room, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_city]), company.city, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_phone]), company.phone, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_state]), company.state, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_zip]), company.zip, **LINE)
    draw_text_box(pdf, at.(FIELDS[:payer_tin], 0), formatted_ein, size: 10)

    tin = employee.form_1099_tin
    recipient_tin = kind == "payer" ? self.class.full_tin(tin) : self.class.truncated_tin(tin)
    draw_text_box(pdf, at.(FIELDS[:recipient_tin], 0), recipient_tin, size: 10)
    draw_text_box(pdf, at.(FIELDS[:recipient_name], 0), recipient_name_lines(employee).join("\n"), **BLOCK)
    street, apt = address_parts(pdf, employee, :recipient_street, :recipient_apt)
    draw_text_box(pdf, at.(FIELDS[:recipient_street]), street, **LINE)
    draw_text_box(pdf, at.(FIELDS[:recipient_apt]), apt, **LINE)
    draw_text_box(pdf, at.(FIELDS[:recipient_city]), employee.city, **LINE)
    draw_text_box(pdf, at.(FIELDS[:recipient_state]), employee.state, **LINE)
    draw_text_box(pdf, at.(FIELDS[:recipient_zip]), employee.zip, **LINE)

    draw_text_box(pdf, at.(FIELDS[:account_number], 0), Form1099Pub1220Generator.account_number(employee), size: 10)

    left, bottom, right, top = at.(FIELDS[:box1a])
    draw_text_box(pdf, [ left, bottom, right - 2, top ], money_string(payee[:row][:total_compensation]), size: 10, align: :right)
    withheld = payee[:row][:federal_withheld].to_d
    return if withheld.zero?

    left, bottom, right, top = at.(FIELDS[:box4])
    draw_text_box(pdf, [ left, bottom, right - 2, top ], money_string(withheld), size: 10, align: :right)
  end

  # The street and unit boxes. A unit that won't fit its narrow box joins the
  # street line instead; nil when even that won't fit.
  def address_parts(pdf, record, street_field, unit_field)
    line1 = record.address_line1.to_s.strip
    line2 = record.address_line2.to_s.strip
    return [ line1, nil ] if line2.blank? && text_fits?(pdf, FIELDS[street_field], line1, **LINE)
    return nil if line2.blank?
    return [ line1, line2 ] if text_fits?(pdf, FIELDS[street_field], line1, **LINE) && text_fits?(pdf, FIELDS[unit_field], line2, **LINE)

    joined = [ line1.presence, line2 ].compact.join(", ")
    [ joined, nil ] if text_fits?(pdf, FIELDS[street_field], joined, **LINE)
  end

  # An individual's full name, with any business (DBA) name on the second
  # line; a business contractor's business name.
  def recipient_name_lines(employee)
    name = [ employee.first_name, employee.middle_name, employee.last_name, employee.name_suffix ].compact_blank.join(" ")
    if employee.business_contractor? && employee.business_name.present?
      [ employee.business_name ]
    else
      [ name, employee.business_name ].compact_blank
    end
  end

  def display_name(employee)
    if employee.business_contractor? && employee.business_name.present?
      employee.business_name
    else
      [ employee.last_name, employee.first_name ].compact_blank.join(", ")
    end
  end

  def formatted_ein
    digits = company.ein.to_s.gsub(/\D/, "")
    digits.length == 9 ? "#{digits[0, 2]}-#{digits[2, 7]}" : company.ein.to_s
  end
end
