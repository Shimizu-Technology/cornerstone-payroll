# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ImportPreviewService do
  describe "#call" do
    it "recovers when a concurrent identical preview creates the import first" do
      company = create(:company)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = { "source" => "aire_services", "employees" => [] }

      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)
      allow(TimeTrackingImport).to receive(:find_or_initialize_by).and_wrap_original do |original, attrs|
        TimeTrackingImport.create!(
          attrs.merge(
            fetch_start_date: TimeTracking::OvertimeCalculator.fetch_start_for(pay_period.start_date),
            fetch_end_date: TimeTracking::OvertimeCalculator.fetch_end_for(pay_period.end_date),
            raw_payload: raw_payload,
            processed_payload: { rows: [] },
            warnings: []
          )
        )
        raise ActiveRecord::RecordNotUnique, "duplicate key value"
      end

      import = described_class.new(pay_period: pay_period, source: source).call

      expect(import).to be_persisted
      expect(import.status).to eq("previewed")
    end
  end
end
