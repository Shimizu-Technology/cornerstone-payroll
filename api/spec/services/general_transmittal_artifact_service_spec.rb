# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeneralTransmittalArtifactService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:transmittal) { create(:general_transmittal, :with_item, company: company) }
  let(:storage) { instance_double(R2StorageService) }

  before do
    allow(storage).to receive(:upload).and_return("local-r2://stored")
    allow(storage).to receive(:delete)
  end

  it "preserves sequential immutable PDF versions with a complete snapshot" do
    first = described_class.new(transmittal: transmittal, actor: actor, storage: storage).generate!
    transmittal.update!(status: "draft", generated_at: nil, title: "Revised title")
    second = described_class.new(transmittal: transmittal, actor: actor, storage: storage).generate!

    expect([ first.artifact.version_number, second.artifact.version_number ]).to eq([ 1, 2 ])
    expect(first.artifact.sha256).to eq(Digest::SHA256.hexdigest(first.pdf_bytes))
    expect(second.artifact.snapshot).to include("title" => "Revised title")
    expect { first.artifact.update!(filename: "changed.pdf") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "verifies stored bytes before returning a generated version" do
    result = described_class.new(transmittal: transmittal, actor: actor, storage: storage).generate!
    allow(storage).to receive(:download_with_limit).and_return(result.pdf_bytes)

    bytes = described_class.new(transmittal: transmittal, actor: actor, storage: storage).download!(result.artifact)

    expect(bytes).to eq(result.pdf_bytes)
  end
end
