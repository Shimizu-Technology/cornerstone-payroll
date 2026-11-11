# frozen_string_literal: true

# Caps list endpoints that previously returned every row. Callers that send no
# paging params get the newest DEFAULT_LIST_PER_PAGE rows; `meta` reports the
# total so a UI can page through the rest.
module BoundedListPagination
  extend ActiveSupport::Concern

  DEFAULT_LIST_PER_PAGE = 200
  MAX_LIST_PER_PAGE = 200

  private

  def bounded_page(scope)
    per_page = params.fetch(:per_page, DEFAULT_LIST_PER_PAGE).to_i.clamp(1, MAX_LIST_PER_PAGE)
    scope.page([ params.fetch(:page, 1).to_i, 1 ].max).per(per_page)
  end

  def bounded_page_meta(collection)
    {
      current_page: collection.current_page,
      total_pages: collection.total_pages,
      total_count: collection.total_count,
      per_page: collection.limit_value
    }
  end
end
