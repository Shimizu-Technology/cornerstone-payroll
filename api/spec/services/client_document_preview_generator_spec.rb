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
end
