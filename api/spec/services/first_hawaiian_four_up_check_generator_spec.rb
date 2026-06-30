# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe FirstHawaiianFourUpCheckGenerator do
  let(:company) do
    create(:company,
      name: "Aire Services LLC",
      check_stock_type: "first_hawaiian_4up",
      check_offset_x: 0,
      check_offset_y: 0)
  end

  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 15),
      pay_date: Date.new(2026, 4, 18))
  end

  def payroll_item_for(first_name, last_name, check_number, net_pay)
    employee = create(:employee,
      company: company,
      first_name: first_name,
      last_name: last_name,
      employment_type: "hourly",
      pay_rate: 20)

    create(:payroll_item, :with_check,
      company: company,
      pay_period: pay_period,
      employee: employee,
      check_number: check_number,
      pay_rate: 20,
      hours_worked: 80,
      gross_pay: net_pay + 100,
      net_pay: net_pay)
  end

  it "renders four payroll checks on one PDF page" do
    items = [
      payroll_item_for("Ana", "Taylor", "2466", 100.25),
      payroll_item_for("Ben", "Cruz", "2467", 200.50),
      payroll_item_for("Caleb", "Ventura", "2468", 300.75),
      payroll_item_for("Dina", "Santos", "2469", 400.00)
    ]

    pdf = described_class.new(company: company, payroll_items: items).generate
    reader = PDF::Reader.new(StringIO.new(pdf))
    text = reader.pages.map(&:text).join("\n")

    expect(pdf).to start_with("%PDF")
    expect(reader.page_count).to eq(1)
    expect(text).to include("Ana Taylor")
    expect(text).to include("Dina Santos")
    expect(text).to include("400.00")
  end

  it "honors a partially used starting slot" do
    items = 5.times.map { |index| payroll_item_for("Emp", "##{index + 1}", (2466 + index).to_s, 125 + index) }

    pdf = described_class.new(company: company, payroll_items: items, starting_slot: 3).generate
    reader = PDF::Reader.new(StringIO.new(pdf))

    expect(reader.page_count).to eq(2)
  end

  it "renders an alignment test" do
    pdf = described_class.new(company: company).alignment_test
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(pdf).to start_with("%PDF")
    expect(text).to include("FIRST HAWAIIAN 4-UP ALIGNMENT TEST")
    expect(text).to include("FHB CHECK SLOT 4")
  end

  it "uses identical relative field placement in all four slots" do
    layout = described_class.resolved_layout_for(company)
    page = described_class.page_layout_metadata(company)
    fields = %w[date payee amount amount_words memo]

    fields.each do |field|
      cfg = layout.fetch("check_face").fetch(field)
      anchors = page.fetch(:slot_count).times.map do |slot_index|
        slot_bottom = page.fetch(:height) - ((slot_index + 1) * page.fetch(:slot_height))
        [ cfg.fetch("x").to_f, slot_bottom + cfg.fetch("y").to_f ]
      end

      expect(anchors.map(&:first).uniq).to eq([ cfg.fetch("x").to_f ])
      anchors.each_cons(2) do |upper_slot, lower_slot|
        expect(upper_slot.first).to eq(lower_slot.first)
        expect(upper_slot.last - lower_slot.last).to eq(page.fetch(:slot_height))
      end
    end
  end

  it "can add progressive slot pitch correction without moving the first slot" do
    company.update!(
      check_layout_config: {
        "calibration" => { "slot_pitch_adjustment" => 7.2 }
      }
    )

    generator = described_class.new(company: company)
    metadata = described_class.page_layout_metadata(company)

    expect(metadata.fetch(:slot_pitch_adjustment)).to eq(7.2)
    expect(metadata.fetch(:slot_pitch)).to eq(described_class::SLOT_HEIGHT + 7.2)
    expect(generator.send(:slot_bottom_for, 0)).to eq(described_class::PAGE_HEIGHT - described_class::SLOT_HEIGHT)
    expect(generator.send(:slot_bottom_for, 1)).to be_within(0.001).of((described_class::PAGE_HEIGHT - described_class::SLOT_HEIGHT) - metadata.fetch(:slot_pitch))
    expect(generator.send(:slot_bottom_for, 3)).to be_within(0.001).of((described_class::PAGE_HEIGHT - described_class::SLOT_HEIGHT) - (3 * metadata.fetch(:slot_pitch)))
  end

  it "keeps default check-face fields within each 4-up slot" do
    layout = described_class.default_layout_config.fetch("check_face")

    layout.each_value do |cfg|
      expect(cfg.fetch("y").to_f).to be_between(0, described_class::SLOT_HEIGHT).inclusive
    end
  end

  it "falls back to default layout fields when custom config is malformed" do
    company.update!(
      check_layout_config: {
        "check_face" => {
          "date" => nil,
          "payee" => "bad override"
        },
        "register" => nil
      }
    )

    item = payroll_item_for("Ana", "Taylor", "2466", 100.25)
    pdf = described_class.new(company: company, payroll_items: [ item ]).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(pdf).to start_with("%PDF")
    expect(text).to include("Ana Taylor")
  end

  it "rejects empty check batches" do
    generator = described_class.new(company: company)

    expect { generator.generate }.to raise_error(ArgumentError, /No check entries/)
  end
end
