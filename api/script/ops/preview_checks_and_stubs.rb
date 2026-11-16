# frozen_string_literal: true

# Manual PREVIEW checks and pay stubs for a calculated or approved pay run, so
# a client can review them before commit. Stopgap until the app has a built-in
# preview; see docs/runbooks/MANUAL_PREVIEW_CHECKS_AND_STUBS.md.
#
# Read-only: everything runs inside a READ ONLY transaction that is rolled
# back, so no check numbers, print events or other records are written. Every
# page is stamped "PREVIEW".
#
#   PAY_PERIOD_ID=132 COMPANY_ID=6 ACTOR_USER_ID=1 bin/rails runner script/ops/preview_checks_and_stubs.rb
#
# Output: a fresh run_<id>_<timestamp> directory under OUT_DIR (default
# /tmp/payroll_preview) holds <prefix>_PREVIEW_paper_checks_<pay date>.pdf and
# <prefix>_PREVIEW_pay_stubs_<pay date>.pdf, so an earlier preview's files are
# never mistaken for this one. Delete OUT_DIR after downloading.
require "combine_pdf"

PAY_PERIOD_ID = Integer(ENV.fetch("PAY_PERIOD_ID"))
COMPANY_ID = Integer(ENV.fetch("COMPANY_ID"))
ACTOR_USER_ID = Integer(ENV.fetch("ACTOR_USER_ID"))
OUT_DIR = ENV.fetch("OUT_DIR", "/tmp/payroll_preview")
PREVIEWABLE_STATUSES = %w[calculated approved].freeze

# Check stubs read YTD from reportable periods, which for a live client are
# committed ones. Like the pay stub (PayStubGenerator#ytd_source_items), add
# this check once when its period is outside that scope, so the preview shows
# the YTD the committed check will show. In-memory for this process only.
CheckGenerator.prepend(Module.new do
  def ytd
    return @preview_ytd if @preview_ytd

    base = super.transform_values(&:to_d)
    unless PayPeriod.reportable_for_company(pay_period.company).exists?(pay_period.id)
      item = payroll_item
      base[:gross] += item.gross_pay.to_d
      base[:fit] += item.withholding_tax.to_d
      base[:ss] += item.social_security_tax.to_d
      base[:med] += item.medicare_tax.to_d
      base[:addl_wh] += item.additional_withholding.to_d
      base[:taxes] = base[:fit] + base[:ss] + base[:med] + base[:addl_wh]
      base[:net] += item.net_pay.to_d
    end
    @preview_ytd = base
  end
end)

# A faint diagonal PREVIEW, a small PREVIEW banner and, on pay stubs, PREVIEW
# over the "official earnings statement" footer.
def watermark_page(width, height, cover_footer: false)
  doc = Prawn::Document.new(page_size: [ width, height ], margin: 0)
  doc.fill_color "C00000"
  doc.transparent(0.18) do
    doc.rotate(35, origin: [ width / 2, height / 2 ]) do
      doc.text_box "PREVIEW", at: [ 0, height / 2 + 65 ], width: width, height: 140,
        size: 110, style: :bold, align: :center
    end
  end
  doc.text_box "PREVIEW",
    at: [ 18, height - 6 ], width: width - 36, height: 12, size: 8, style: :bold, align: :center, overflow: :shrink_to_fit
  if cover_footer
    doc.fill_color "FFFFFF"
    doc.fill_rectangle [ 0, 52 ], width, 52
    doc.fill_color "C00000"
    doc.text_box "PREVIEW",
      at: [ 18, 34 ], width: width - 36, height: 14, size: 8, style: :bold, align: :center, overflow: :shrink_to_fit
  end
  CombinePDF.parse(doc.render).pages[0]
end

def stamp(pdf_data, cover_footer: false)
  pdf = CombinePDF.parse(pdf_data)
  cache = {}
  pdf.pages.each do |page|
    box = page.mediabox || [ 0, 0, 612, 792 ]
    w, h = box[2] - box[0], box[3] - box[1]
    page << (cache[[ w, h ]] ||= watermark_page(w, h, cover_footer: cover_footer))
  end
  pdf.to_pdf
end

results = {}
ApplicationRecord.transaction do
  ApplicationRecord.connection.execute("SET TRANSACTION READ ONLY")
  period = PayPeriod.find(PAY_PERIOD_ID)
  abort "Pay period #{PAY_PERIOD_ID} belongs to company #{period.company_id}, not #{COMPANY_ID}" unless period.company_id == COMPANY_ID
  abort "Expected a calculated or approved run, found #{period.status}" unless PREVIEWABLE_STATUSES.include?(period.status)

  items = period.payroll_items.reportable.not_voided
    .includes(:payroll_item_earnings, :payroll_item_field_entries,
      { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
    .to_a
    .sort_by { |item| [ item.employee.last_name.to_s.downcase, item.employee.first_name.to_s.downcase, item.id ] }

  checks = items.select { |item| item.effective_payment_delivery_method == "paper_check" && item.net_pay.to_d.positive? }
  render_company = CheckRenderSettings.resolve(company: period.company, actor: User.find(ACTOR_USER_ID), require_profile: false)
    .apply_to(period.company)
  check_pdf = if checks.empty?
    nil
  elsif render_company.first_hawaiian_4up_checks?
    FirstHawaiianFourUpCheckGenerator.new(company: render_company, payroll_items: checks).generate
  else
    # One document, like CheckGenerator.generate_rehearsal_batch, without VOID marks.
    PdfUnicodeFont.document(page_size: [ CheckGenerator::PAGE_WIDTH, CheckGenerator::PAGE_HEIGHT ],
      page_layout: :portrait, margin: CheckGenerator::MARGIN) do |pdf|
      checks.each_with_index do |item, index|
        pdf.start_new_page unless index.zero?
        CheckGenerator.new(item, company: render_company).send(:draw_document, pdf)
      end
    end.render
  end

  stubs = items.select { |item| EarningsStatementEligibility.printable?(item) }
  stub_pdf = CombinePDF.new
  stubs.each { |item| stub_pdf << CombinePDF.parse(PayStubGenerator.new(item).generate) }

  prefix = period.company.name.to_s.gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").first(40)
  pay_date = period.pay_date&.strftime("%Y-%m-%d") || "undated"
  results["#{prefix}_PREVIEW_paper_checks_#{pay_date}.pdf"] = stamp(check_pdf) if check_pdf
  results["#{prefix}_PREVIEW_pay_stubs_#{pay_date}.pdf"] = stamp(stub_pdf.to_pdf, cover_footer: true) if stubs.any?
  puts "run=#{period.id} status=#{period.status} employees=#{items.size} paper_checks=#{checks.size} stubs=#{stubs.size} " \
    "direct_deposit=#{stubs.count { |i| i.effective_payment_delivery_method == 'direct_deposit' }} " \
    "paper_check_net=#{checks.sum { |i| i.net_pay.to_d }.to_s('F')} total_net=#{items.sum { |i| i.net_pay.to_d }.to_s('F')} " \
    "stock=#{render_company.check_stock_type}"
  raise ActiveRecord::Rollback
end

run_dir = File.join(OUT_DIR, "run_#{PAY_PERIOD_ID}_#{Time.current.utc.strftime('%Y%m%d%H%M%S')}")
FileUtils.mkdir_p(run_dir)
results.each do |name, data|
  File.binwrite(File.join(run_dir, name), data)
  puts "#{File.join(run_dir, name)} #{data.bytesize} bytes"
end
puts "Run #{PAY_PERIOD_ID} status after: #{PayPeriod.find(PAY_PERIOD_ID).status}"
