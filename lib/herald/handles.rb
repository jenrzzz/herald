module Herald
  # One way to compare the ways a person is written down. Messages keeps a
  # handle as it first saw it (+15551234567, 5551234567, ana@example.com) and
  # Contacts as a person typed it ((555) 123-4567); a scope names people the
  # way whoever made the key did. An address compares in any case; a phone
  # number by its last ten digits, so a country code and punctuation do not
  # matter. Two numbers in different countries sharing ten digits would
  # collide; for one household's contacts that is a risk worth taking.
  # Anything with neither an @ nor a digit is not a handle at all.
  module Handles
    module_function

    def key(handle)
      text = handle.to_s.strip
      return nil if text.empty?
      return text.downcase if text.include?("@")

      digits = text.gsub(/\D/, "")
      return nil if digits.empty?

      digits.length > 10 ? digits[-10..] : digits
    end

    def same?(a, b)
      left = key(a)
      !left.nil? && left == key(b)
    end
  end
end
