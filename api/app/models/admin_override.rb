# frozen_string_literal: true

class AdminOverride < ApplicationRecord
  belongs_to :company
  belongs_to :actor, class_name: "User"
  belongs_to :real_user, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true

  def readonly?
    persisted?
  end
end
