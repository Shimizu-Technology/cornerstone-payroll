# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayRunActivityPhrase do
  describe ".worker_headline" do
    it "uses the supplied source name" do
      log = AuditLog.new(action: "worker_statement#viewed", subject_name: "Alex Cruz", metadata: { "source_name" => "AIRE Payroll" })

      expect(described_class.worker_headline(log)).to eq("Alex Cruz viewed their pay stub in AIRE Payroll")
    end

    it "uses the default AIRE app name when the source is missing" do
      log = AuditLog.new(action: "worker_statement#pdf_downloaded", metadata: {})

      expect(described_class.worker_headline(log)).to eq("A worker downloaded their pay stub PDF from the AIRE app")
    end
  end
end
