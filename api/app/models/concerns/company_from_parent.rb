# frozen_string_literal: true

module CompanyFromParent
  extend ActiveSupport::Concern

  class_methods do
    def inherit_company_from(parent_association)
      before_save do
        self.company_id ||= public_send(parent_association)&.company_id
      end
    end
  end
end
