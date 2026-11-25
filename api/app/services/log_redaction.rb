# frozen_string_literal: true

# Log lines name an email address by its domain only.
module LogRedaction
  module_function

  def email(address)
    domain = address.to_s.strip.downcase.split("@", 2)[1]
    domain.present? ? "***@#{domain}" : "[no address]"
  end
end
