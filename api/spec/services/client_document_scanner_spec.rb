# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentScanner do
  let(:document) { create(:client_document) }

  it "leaves legacy and newly scanned no-op files not_scanned, never clean" do
    expect(document.scan_status).to eq("not_scanned")
    described_class.scan!(document)
    expect(document.reload.scan_status).to eq("not_scanned")
    described_class::PURPOSES.each { |purpose| expect { document.ensure_usable_for!(purpose) }.not_to raise_error }
  end

  context "with an enforcing adapter" do
    before do
      adapter = double(initial_status: "pending")
      allow(adapter).to receive(:allowed?) { |document:, purpose:| document.scan_status == "clean" }
      allow(adapter).to receive(:scan).and_return("clean")
      allow(described_class).to receive(:adapter).and_return(adapter)
    end

    it "blocks every consumption gate until clean, including future intake" do
      %w[not_scanned pending infected error].each do |status|
        document.update!(scan_status: status)
        described_class::PURPOSES.each do |purpose|
          expect { document.ensure_usable_for!(purpose) }.to raise_error(described_class::Blocked)
        end
      end
      described_class.scan!(document)
      expect(document.reload.scan_status).to eq("clean")
      described_class::PURPOSES.each { |purpose| expect { document.ensure_usable_for!(purpose) }.not_to raise_error }
    end

    it "records infected and unavailable results without claiming clean" do
      allow(described_class.adapter).to receive(:scan).and_return("infected")
      described_class.scan!(document)
      expect(document.reload.scan_status).to eq("infected")
      allow(described_class.adapter).to receive(:scan).and_raise(IOError, "scanner unavailable")
      expect { described_class.scan!(document) }.to raise_error(IOError)
      expect(document.reload.scan_status).to eq("error")
    end
  end
end
