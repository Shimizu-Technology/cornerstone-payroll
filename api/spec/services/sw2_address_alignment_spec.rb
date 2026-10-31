# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe QuarterlyComplianceOfficialForms::Sw2 do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, address_line1: "123 Marine Corps Drive", address_line2: "Unit 7", city: "Tamuning", state: "GU", zip: "96913") }
  let(:rows) { 12.times.map { { employee_id: employee.id, name: employee.full_name, swica_wages: 100, guam_withholding: 10 } } }
  let(:report) { { meta: { company_id: company.id, year: 2026, quarter: 3, quarter_end: "2026-09-30" }, swica: { employees: rows } } }
  let(:widgets) do
    reader = PDF::Reader.new(described_class::TEMPLATE_PATH.to_s)
    reader.objects[reader.pages.first.attributes.fetch(:Annots)].to_h do |ref|
      widget = reader.objects[ref]
      [ widget[:T] || reader.objects[widget[:Parent]]&.dig(:T), widget[:Rect] ]
    end
  end

  def generated_pages
    PDF::Reader.new(StringIO.new(described_class.new(report: report).generate)).pages
  end

  def runs_inside(page, rect)
    left, bottom, right, top = rect
    page.runs.select { |run| run.x.between?(left, right) && run.y.between?(bottom, top) }
  end

  it "uses every official street/city and ZIP widget, including the last row and second page" do
    names = %w[Text1571 Text1572 Text1579 Text1580 Text1587 Text1588 Text1595 Text1596 Text1603 Text1610 Text1611 Text1618 Text1619 Text1626 Text1627 Text1634 Text1635 Text1642 Text1643 Text1650 Text1651 Text1652]
    expect(described_class::ADDRESS_RECTS).to eq(names.each_slice(2).map { |pair| pair.map { |name| widgets.fetch(name) } })
    expect(described_class::ZIP_RECTS).to eq(%w[Text1573 Text1581 Text1589 Text1597 Text1604 Text1612 Text1620 Text1628 Text1636 Text1644 Text1653].map { |name| widgets.fetch(name) })
    generated_pages.each_with_index do |page, page_index|
      (page_index.zero? ? 11 : 1).times do |index|
        street, city = described_class::ADDRESS_RECTS[index]
        expect(runs_inside(page, street).map(&:text).join).to eq("123 Marine Corps Drive Unit 7")
        expect(runs_inside(page, city).map(&:text).join).to eq("Tamuning, GU 96913")
        expect(runs_inside(page, described_class::ZIP_RECTS[index]).map(&:text).join).to eq("96913")
      end
    end
  end

  it "shrinks a long street, moves a unit to line two, and never crosses the address border" do
    employee.update!(address_line1: "12345 Marine Corps Drive Northern Extension Road", address_line2: "Suite 456")
    page = generated_pages.first
    street, city = described_class::ADDRESS_RECTS.first
    street_runs = runs_inside(page, street)
    expect(street_runs.map(&:text).join).to eq(employee.address_line1)
    expect(street_runs.map(&:font_size).max).to be < 7.5
    expect(street_runs.map(&:font_size).min).to be >= 6
    expect(runs_inside(page, city).map(&:text).join).to eq("Suite 456; Tamuning, GU 96913")
    [ street, city ].each do |rect|
      runs_inside(page, rect).each do |run|
        expect(run.x + run.width).to be <= rect[2]
        expect(run.y + run.font_size).to be <= rect[3]
      end
    end
  end

  it "truncates only an overflowing unit and preserves city, state and ZIP" do
    employee.update!(address_line1: "123 Marine Corps Drive", address_line2: "ExtremelyLongUnitDescription" * 10)
    page = generated_pages.first
    street, city = described_class::ADDRESS_RECTS.first
    city_text = runs_inside(page, city).map(&:text).join
    expect(city_text).to end_with("...; Tamuning, GU 96913")
    expect(runs_inside(page, street).map(&:text).join).to eq(employee.address_line1)
    expect(runs_inside(page, described_class::ZIP_RECTS.first).map(&:text).join).to eq("96913")
    runs_inside(page, city).each { |run| expect(run.x + run.width).to be <= city[2] }
  end

  it "keeps exceptionally long values readable with an ellipsis" do
    employee.update!(address_line1: "ExtraordinarilyLongUnbrokenStreet" * 8)
    run = runs_inside(generated_pages.first, described_class::ADDRESS_RECTS.first.first).first
    expect(run.text).to end_with("...")
    expect(run.font_size).to be >= 6
    expect(run.x + run.width).to be <= described_class::ADDRESS_RECTS.first.first[2]
  end

  it "prints partial addresses, blanks absent addresses and invalid SSNs, and scopes profiles to the report company" do
    employee.update_columns(address_line1: nil, address_line2: nil, city: "Tamuning", state: nil, zip: nil, ssn_encrypted: nil)
    page = generated_pages.first
    expect(runs_inside(page, described_class::ADDRESS_RECTS.first.last).map(&:text).join).to eq("Tamuning")
    employee.update_columns(city: nil)
    expect(generated_pages.first.text).not_to include("Tamuning", "123 Marine", employee.ssn_last_four.to_s.presence || "DO_NOT_MATCH")
    employee.update_columns(ssn_encrypted: "12345")
    expect(generated_pages.first.text).not_to include("123-45-")
    report[:meta][:company_id] = create(:company).id
    employee.update_columns(address_line1: "Private Other Company Address")
    expect(generated_pages.first.text).not_to include("Private Other Company Address")
  end
end
