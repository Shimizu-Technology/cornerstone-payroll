# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentPreviewGenerator do
  describe "#prepare_source_file" do
    it "writes preview source files using a basename inside the temp directory" do
      document = instance_double(
        ClientDocument,
        file_name: "../../outside/evil.txt",
        file_key: "client_documents/test/evil.txt",
        file_extension: "txt"
      )
      storage = instance_double(R2StorageService, download: "preview-source")
      generator = described_class.new(document: document, storage: storage)

      Dir.mktmpdir("preview-generator-spec") do |dir|
        source_path = generator.send(:prepare_source_file, dir)

        expect(File.dirname(source_path)).to eq(dir)
        expect(File.basename(source_path)).to eq("evil.txt")
        expect(File.read(source_path)).to eq("preview-source")
      end
    end
  end

  describe "#generate!" do
    let(:company) { create(:company) }
    let(:document) do
      create(
        :client_document,
        company: company,
        file_name: "timecard.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        file_key: "client_documents/test/timecard.xlsx",
        preview_status: "pending",
        preview_file_key: "client_documents/test/old-preview.pdf"
      )
    end
    let(:storage) { instance_double(R2StorageService, download: "spreadsheet-source", upload: nil, delete: nil) }
    let(:generator) { described_class.new(document: document, storage: storage) }
    let(:success_status) { instance_double(Process::Status, success?: true) }

    before do
      allow(generator).to receive(:libreoffice_binary).and_return("soffice")
      allow(generator).to receive(:build_preview_key).and_return("client_documents/test/new-preview.pdf")
      allow(generator).to receive(:optimize_spreadsheet_layout!)
      allow(Open3).to receive(:capture3) do |*_args|
        output_dir = _args[_args.index("--outdir") + 1]
        File.binwrite(File.join(output_dir, "preview.pdf"), "%PDF-1.4\npreview")
        [ "", "", success_status ]
      end
    end

    it "keeps the previous preview key when persisting the new preview metadata fails" do
      allow(document).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(document))

      expect(storage).to receive(:upload).with("client_documents/test/new-preview.pdf", kind_of(File), content_type: "application/pdf")
      expect(storage).to receive(:delete).with("client_documents/test/new-preview.pdf")
      expect(storage).not_to receive(:delete).with("client_documents/test/old-preview.pdf")

      expect { generator.generate! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(document.reload.preview_file_key).to eq("client_documents/test/old-preview.pdf")
      expect(document.reload.preview_status).to eq("pending")
    end
  end
end
