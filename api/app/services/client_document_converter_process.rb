# frozen_string_literal: true

require "open3"
require "timeout"

# Each converter gets its own process group. Bounded output drains concurrently;
# timeout kills the whole group (including LibreOffice's child processes).
class ClientDocumentConverterProcess
  TIMEOUT_SECONDS = 45
  MAX_OUTPUT_BYTES = 64.kilobytes
  MAX_FILE_BYTES = 100.megabytes

  def self.capture(*command, timeout: TIMEOUT_SECONDS, directory:)
    command = network_sandbox(command, directory)
    options = { pgroup: true, chdir: directory, rlimit_cpu: 30, rlimit_fsize: MAX_FILE_BYTES, rlimit_nofile: 128, unsetenv_others: true }
    # LibreOffice reserves large virtual mappings at startup. Limit Linux's
    # data/heap to 1 GiB instead of all virtual address space; CPU, wall time,
    # output and descriptor limits still apply on both platforms.
    options[:rlimit_data] = 1.gigabyte unless RUBY_PLATFORM.include?("darwin")
    environment = { "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"), "HOME" => directory, "TMPDIR" => directory, "LANG" => "C.UTF-8" }
    Open3.popen3(environment, *command, **options) do |stdin, stdout, stderr, process|
      stdin.close
      readers = [ stdout, stderr ].map do |io|
        Thread.new do
          captured = +""
          loop do
            chunk = io.readpartial(4.kilobytes)
            captured << chunk.byteslice(0, [ MAX_OUTPUT_BYTES - captured.bytesize, 0 ].max)
          end
        rescue EOFError
          captured
        end
      end
      begin
        Timeout.timeout(timeout) { [ *readers.map(&:value), process.value ] }
      rescue Timeout::Error
        raise ClientDocumentPreviewGenerator::GenerationFailed, "Preview took too long. Please try again or download the original file."
      ensure
        # Also terminate descendants left behind after the launcher exits.
        begin
          Process.kill("KILL", -process.pid)
        rescue Errno::ESRCH
          nil
        end
        readers.each(&:join)
      end
    end
  end

  def self.network_sandbox(command, directory)
    if RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/bin/sandbox-exec")
      [ "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)(allow network* (local unix-socket) (remote unix-socket))", *command ]
    elsif File.executable?("/usr/bin/bwrap")
      [ "/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--ro-bind", "/", "/", "--bind", directory, directory, "--dev", "/dev", "--proc", "/proc", "--", *command ]
    else
      # Deployment must provide bwrap with user namespaces for network isolation.
      # Resource bounds still apply when this optional sandbox is unavailable.
      command
    end
  end
end
