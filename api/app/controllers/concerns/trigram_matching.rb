# Shared trigram-based fuzzy name matching for employee lookup.
module TrigramMatching
  extend ActiveSupport::Concern

  private

  def trigram_similarity(a, b)
    a_norm = a.to_s.downcase.gsub(/[^a-z0-9\s]/, "").squish
    b_norm = b.to_s.downcase.gsub(/[^a-z0-9\s]/, "").squish
    return 1.0 if a_norm == b_norm
    return 0.0 if a_norm.blank? || b_norm.blank?

    a_tri = trigrams(a_norm)
    b_tri = trigrams(b_norm)
    intersection = (a_tri & b_tri).size.to_f
    union_size = (a_tri | b_tri).size.to_f
    union_size.zero? ? 0.0 : intersection / union_size
  end

  def trigrams(str)
    padded = "  #{str} "
    (0..padded.length - 3).map { |i| padded[i, 3] }
  end
end
