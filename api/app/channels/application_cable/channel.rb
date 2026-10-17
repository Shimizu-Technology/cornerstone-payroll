# frozen_string_literal: true

module ApplicationCable
  class Channel < ActionCable::Channel::Base
    delegate :current_company, to: :connection
  end
end
