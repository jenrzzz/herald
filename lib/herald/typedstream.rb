module Herald
  # The text of a message from its attributedBody: an NSAttributedString in
  # NeXT's typedstream archive format, which is all newer Messages keeps for
  # most messages (`message.text` is null). herald needs only the string, not
  # the attributes, and the string is the first object after the NSString
  # class: a `+` (the C-string type tag), a length, then UTF-8.
  #
  # The length is one byte below 0x80; 0x81 says a 2-byte little-endian
  # length follows, 0x82 a 4-byte one. Anything that does not parse is nil,
  # never an exception: one odd row must not fail a listing.
  module Typedstream
    MARKER = "NSString".b
    TAG = "\x01+".b

    module_function

    def text(blob)
      return nil if blob.nil? || blob.empty?

      data = blob.b
      at = data.index(MARKER) or return nil
      at = data.index(TAG, at + MARKER.bytesize) or return nil
      length, at = length_at(data, at + TAG.bytesize)
      return nil if length.nil? || at + length > data.bytesize

      data.byteslice(at, length).force_encoding(Encoding::UTF_8).scrub
    end

    def length_at(data, at)
      case data.getbyte(at)
      when nil then nil
      when 0x81 then [ data.byteslice(at + 1, 2)&.unpack1("v"), at + 3 ]
      when 0x82 then [ data.byteslice(at + 1, 4)&.unpack1("V"), at + 5 ]
      else [ data.getbyte(at), at + 1 ]
      end
    end
  end
end
