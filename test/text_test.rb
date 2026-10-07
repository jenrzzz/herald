require_relative "test_helper"

# The two small things everything else leans on: getting the words out of
# an attributedBody, and telling when two handles are the same person.
class TextTest < Minitest::Test
  def test_typedstream_lengths_of_every_size
    [ "hi", "Running 10 late 🏃‍♀️", "x" * 200, "y" * 70_000 ].each do |text|
      assert_equal text, Herald::Typedstream.text(FixtureMessages.attributed(text)), "#{text.bytesize} bytes"
    end
  end

  def test_typedstream_what_does_not_parse_is_nil
    assert_nil Herald::Typedstream.text(nil)
    assert_nil Herald::Typedstream.text("")
    assert_nil Herald::Typedstream.text("streamtyped but no string")
    truncated = FixtureMessages.attributed("hello world")
    assert_nil Herald::Typedstream.text(truncated[0, truncated.index("hello") + 3])
  end

  def test_handles
    assert_equal "5551234567", Herald::Handles.key("+1 (555) 123-4567")
    assert_equal "5551234567", Herald::Handles.key("5551234567")
    assert_equal "ana@example.com", Herald::Handles.key(" Ana@Example.com ")
    assert_equal "12345", Herald::Handles.key("12345"), "a short code"
    assert_nil Herald::Handles.key("  ")
    assert Herald::Handles.same?("+15551234567", "555.123.4567")
    refute Herald::Handles.same?("", "")
  end

  def test_contacts_names_and_finding_by_name
    Dir.mktmpdir do |dir|
      contacts = Herald::Contacts.new(root: FixtureContacts.new(dir, { "Ana Ruiz" => [ "(555) 123-4567", "ana@example.com" ] }).root)
      assert_equal [ "Ana Ruiz", "Ana Ruiz", nil ], [ contacts.name("+15551234567"), contacts.name("ANA@example.com"), contacts.name("+15550000000") ]
      assert_equal %w[5551234567 ana@example.com].sort, contacts.handles_named("ruiz").sort
      assert_equal 1, contacts.count
    end
    assert_nil Herald::Contacts.new(root: "/nonexistent").count
  end
end
