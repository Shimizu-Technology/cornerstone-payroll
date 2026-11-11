# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentConverterProcess do
  it "terminates a real process group on timeout" do
    Dir.mktmpdir do |dir|
      allow(described_class).to receive(:network_sandbox) { |command, _directory| command }
      expect do
        described_class.capture(RbConfig.ruby, "-e", "sleep 10", timeout: 0.1, directory: dir)
      end.to raise_error(ClientDocumentPreviewGenerator::GenerationFailed, /too long/)
    end
  end

  it "bounds output without deadlocking a noisy converter" do
    Dir.mktmpdir do |dir|
      allow(described_class).to receive(:network_sandbox) { |command, _directory| command }
      out, err, status = described_class.capture(RbConfig.ruby, "-e", "$stdout.write('x' * 200000); $stderr.write('y' * 200000)", directory: dir)
      expect(status).to be_success
      expect(out.bytesize).to eq(described_class::MAX_OUTPUT_BYTES)
      expect(err.bytesize).to eq(described_class::MAX_OUTPUT_BYTES)
    end
  end
end

RSpec.describe "macOS converter network isolation" do
  it "permits local Unix IPC for LibreOffice while denying IP networking" do
    skip "macOS sandbox-exec contract" unless RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/bin/sandbox-exec")
    Dir.mktmpdir do |dir|
      script = <<~CODE
        require 'socket'
        server = UNIXServer.new('ipc.sock')
        client = UNIXSocket.new('ipc.sock')
        peer = server.accept
        [client, peer, server].each(&:close)
        begin
          TCPSocket.new('127.0.0.1', 9)
          abort 'IP networking was allowed'
        rescue Errno::EPERM
          puts 'Unix IPC allowed; IP networking blocked'
        end
      CODE
      out, err, status = ClientDocumentConverterProcess.capture(RbConfig.ruby, "-e", script, directory: dir)
      expect(status).to be_success, err
      expect(out).to include("Unix IPC allowed; IP networking blocked")
    end
  end
end
