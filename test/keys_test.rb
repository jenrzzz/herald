require_relative "test_helper"

class KeysTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("herald-keys")
    @keys = Herald::Keys.new(File.join(@dir, "keys.json"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_a_token_is_shown_once_and_only_its_digest_kept
    token = @keys.add("hob", permissions: %w[read send])
    assert token.start_with?("hrd_")
    refute_includes File.read(@keys.path), token
    assert_equal 0o600, File.stat(@keys.path).mode & 0o777
    key = @keys.authenticate(token)
    assert_equal [ "hob", true, true ], [ key.name, key.may?(:read), key.may?("send") ]
    assert_nil key.confinement
    assert_nil @keys.authenticate("hrd_nope")
    assert_nil @keys.authenticate("")
  end

  def test_adding_a_name_again_rotates_it
    old = @keys.add("hob")
    fresh = @keys.add("hob", permissions: %w[read])
    assert_nil @keys.authenticate(old)
    assert_equal "hob", @keys.authenticate(fresh).name
    assert_equal 1, @keys.all.size
  end

  def test_scopes
    token = @keys.add("family", permissions: %w[read], scope: { chats: [ "any;+;chat100", " " ], handles: [ "(555) 123-4567" ] })
    scope = @keys.authenticate(token).confinement
    assert_equal [ "any;+;chat100" ], scope.chats
    assert scope.handle?("+15551234567")
    refute scope.handle?("+15559990000")
    assert_nil @keys.authenticate(@keys.add("x", scope: { chats: [], handles: [] })).scope, "an empty scope is no scope"
  end

  def test_refusals
    assert_raises(Herald::Keys::Error) { @keys.add("bad name") }
    assert_raises(Herald::Keys::Error) { @keys.add("x", permissions: %w[write]) }
    assert_raises(Herald::Keys::Error) { @keys.add("x", permissions: []) }
    assert_raises(Herald::Keys::Error) { @keys.add("x", scope: { folders: [ "a" ] }) }
    assert_raises(Herald::Keys::Error) { @keys.add("x", scope: { handles: [ "---" ] }) }
  end

  def test_revoke
    token = @keys.add("hob")
    assert @keys.revoke("hob")
    refute @keys.revoke("hob")
    assert_nil @keys.authenticate(token)
  end
end
