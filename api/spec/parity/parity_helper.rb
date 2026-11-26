# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

Rails.root.glob("spec/parity/support/**/*.rb").sort_by(&:to_s).each { |file| require file }
