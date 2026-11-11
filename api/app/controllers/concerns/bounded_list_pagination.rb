# frozen_string_literal: true

# Caps list endpoints that previously returned every row. Callers that send no
# paging params get the newest DEFAULT_LIST_PER_PAGE rows; `meta` reports the
# total so a UI can page through the rest. Scopes passed in must end their
# ORDER BY with the primary key so pages never repeat or skip a row.
module BoundedListPagination
  extend ActiveSupport::Concern

  DEFAULT_LIST_PER_PAGE = 200
  MAX_LIST_PER_PAGE = 200

  private

  def bounded_page(scope)
    scope.page([ params[:page].to_i, 1 ].max).per(bounded_per_page)
  end

  # A blank, zero, negative or non-numeric per_page falls back to the default
  # instead of collapsing to one row.
  def bounded_per_page(default: DEFAULT_LIST_PER_PAGE, max: MAX_LIST_PER_PAGE)
    requested = params[:per_page].to_i
    requested.positive? ? [ requested, max ].min : default
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
