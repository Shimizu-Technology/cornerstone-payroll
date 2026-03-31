require "fileutils"
require "uri"

module TimecardOcr
  class StorageService
    class << self
      def upload(file_path, key, content_type: "application/octet-stream")
        data = File.binread(file_path)
        r2.upload("timecards/#{key}", data, content_type: content_type)
        key
      end

      def download_to_tempfile(reference)
        key = normalize_key(reference)
        data = r2.download("timecards/#{key}")
        raise Errno::ENOENT, "File not found in R2: #{key}" unless data

        tmp = Tempfile.new(["timecard", File.extname(key).presence || ".jpg"])
        tmp.binmode
        tmp.write(data)
        tmp.rewind
        tmp
      end

      def presigned_url(reference, expires_in: 3600)
        return nil if reference.blank?

        key = normalize_key(reference)
        r2.signed_url("timecards/#{key}", expires_in: expires_in)
      end

      private

      def r2
        @r2 ||= R2StorageService.new
      end

      def normalize_key(reference)
        return reference unless reference.to_s.start_with?("http://", "https://", "r2://")

        if reference.start_with?("r2://")
          reference.sub(%r{\Ar2://[^/]+/}, "").sub(%r{\Atimecards/}, "")
        else
          uri = URI.parse(reference)
          uri.path.sub(%r{\A/}, "").sub(%r{\Atimecards/}, "")
        end
      end
    end
  end
end
