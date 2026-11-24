# frozen_string_literal: true

# Refuses an oversized employee-app logo upload before Rack parses the
# multipart body to temp disk. Only the two logo upload routes are limited;
# every other upload keeps its own limits.
#
# The cap allows the 1 MB file plus multipart overhead. A file that fits
# under the cap but is over 1 MB still gets the controller's 422.
class LogoUploadBodyLimit
  PATH = %r{\A/api/v1/(?:admin|client)/employee_app_settings/logo/?\z}
  MAX_BODY_BYTES = 1_572_864 # 1.5 MB
  HEADERS = { "content-type" => "application/json", "cache-control" => "no-store" }.freeze
  TOO_LARGE = "The logo must be 1 MB or smaller. Export a smaller PNG or WebP and try again."
  NO_LENGTH = "The upload didn't say how large it is. Try again from the Employee app page."

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST"

    path = ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"])
    return @app.call(env) unless PATH.match?(path)

    length = env["CONTENT_LENGTH"]
    # Chunked uploads have no length to check up front; browsers always send one.
    return reject(411, NO_LENGTH) if length.nil? || length.empty? || env["HTTP_TRANSFER_ENCODING"].present?
    return reject(413, TOO_LARGE) if !length.match?(/\A\d+\z/) || length.to_i > MAX_BODY_BYTES

    @app.call(env)
  end

  private

  def reject(status, message)
    [ status, HEADERS.dup, [ JSON.generate(error: message) ] ]
  end
end
