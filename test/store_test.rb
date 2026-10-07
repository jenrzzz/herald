require_relative "test_helper"

class StoreTest < Minitest::Test
  include Household

  def setup
    build_household
    @store = Herald.store
  end

  def teardown
    teardown_household
  end

  def scope(chats: [], handles: [])
    Herald::Keys::Scope.new(chats, handles)
  end

  def test_chats_newest_first_named_from_contacts_with_unread
    chats = @store.chats
    assert_equal %w[any;-;+15559990000 any;-;+15552223333 any;+;chat100 any;-;+15551234567], chats.map { |c| c["id"] }
    ana = chats.last
    assert_equal({ "id" => "any;-;+15551234567", "identifier" => "+15551234567", "service" => "iMessage", "group" => false,
                   "name" => "Ana Ruiz", "display_name" => nil,
                   "participants" => [ { "handle" => "+15551234567", "name" => "Ana Ruiz" } ],
                   "last_message_at" => "2026-10-06T16:02:00Z", "unread" => 1 }, ana)
    family = chats.find { |c| c["group"] }
    assert_equal [ "Family", 1 ], family.values_at("name", "unread"), "the tapbacks and the rename are not unread messages"
    assert_equal "+15559990000", chats.first["name"], "no contact: the handle"
  end

  def test_chats_filters
    assert_equal [ "any;+;chat100" ], @store.chats(q: "family").map { |c| c["id"] }
    assert_equal %w[any;+;chat100 any;-;+15551234567], @store.chats(q: "ana").map { |c| c["id"] }
    assert_equal 3, @store.chats(active_after: Household::T0 + 300).size, "the group was renamed at +350: activity, if not a message"
    assert_equal 1, @store.chats(limit: 1).size
    assert_equal "Ana Ruiz", @store.chat("+15551234567")["name"], "by identifier too"
    assert_raises(Herald::Store::NotFound) { @store.chat("any;-;nobody") }
  end

  def test_messages_newest_first_with_text_decoded
    page = @store.messages
    assert_equal [ @stranger, @gone, @dinner, @photo, @reply, @late, @hello ], page["messages"].map { |m| m["id"] }
    assert_equal [ 7, false, nil ], page.values_at("count", "truncated", "searched_back_to")
    late = page["messages"].find { |m| m["id"] == @late }
    assert_equal({ "id" => @late, "seq" => @messages.seq(@late), "chat_id" => "any;-;+15551234567", "from_me" => false,
                   "sender" => { "handle" => "+15551234567", "name" => "Ana Ruiz" }, "text" => "Running 10 late, save me a seat",
                   "sent_at" => "2026-10-06T16:01:00Z", "read_at" => nil, "delivered_at" => nil, "read" => false,
                   "service" => "iMessage", "reply_to" => nil, "edited" => false, "unsent" => false, "attachments" => [],
                   "reactions" => [] }, late)
  end

  def test_a_reply_from_me
    reply = @store.message(@reply)
    assert_equal [ true, nil, "No problem", @late, "2026-10-06T16:02:01Z", "2026-10-06T16:03:00Z", true ],
                 reply.values_at("from_me", "sender", "text", "reply_to", "delivered_at", "read_at", "read")
  end

  def test_tapbacks_fold_onto_their_message_and_one_taken_back_is_gone
    dinner = @store.message(@dinner)
    assert_equal [ { "reaction" => "loved", "emoji" => nil, "from_me" => false, "from" => { "handle" => "+15551234567", "name" => "Ana Ruiz" } },
                   { "reaction" => "emoji", "emoji" => "🍝", "from_me" => true, "from" => nil } ], dinner["reactions"]
  end

  def test_attachments_named_and_hidden_ones_left_out_and_the_placeholder_removed
    photo = @store.message(@photo)
    assert_nil photo["text"]
    assert_equal [ { "name" => "IMG_1.HEIC", "type" => "image/heic", "size" => 1200 } ], photo["attachments"]
  end

  def test_unsent_has_no_text
    assert_equal [ true, nil ], @store.message(@gone).values_at("unsent", "text")
  end

  def test_message_filters
    ids = ->(**filters) { @store.messages(**filters)["messages"].map { |m| m["id"] } }
    assert_equal [ @reply, @late, @hello ], ids.call(chat: "any;-;+15551234567")
    assert_equal [ @dinner, @reply ], ids.call(from: "me")
    assert_equal [ @late, @hello ], ids.call(from: "ana"), "a name from Contacts"
    assert_equal [ @late, @hello ], ids.call(from: "555-123-4567"), "a number however it is written"
    assert_equal [ @stranger ], ids.call(from: "9990000")
    assert_equal [], ids.call(from: "nobody at all")
    assert_equal [ @late ], ids.call(q: "SAVE seat"), "words decoded from attributedBody, any case"
    assert_equal [ @dinner, @photo ], ids.call(after: Household::T0 + 200, before: Household::T0 + 400)
    assert_equal [ @stranger, @gone, @photo, @late ], ids.call(unread: true)
    assert_equal [ @dinner, @reply, @hello ], ids.call(unread: false)
    page = @store.messages(limit: 2)
    assert_equal [ 2, true ], page.values_at("count", "truncated")
  end

  def test_search_stops_after_reading_its_limit_and_says_how_far_back
    stub_const(Herald::Store, :SEARCH_LIMIT, 3) do
      stub_const(Herald::Store, :BATCH, 2) do
        page = @store.messages(q: "hello")
        assert_equal [ [], "2026-10-06T16:03:20Z" ], [ page["messages"], page["searched_back_to"] ]
        assert_equal [ @hello ], @store.messages(q: "hello", chat: "any;-;+15551234567")["messages"].map { |m| m["id"] }
      end
    end
  end

  def test_changes
    first = @store.changes
    assert_equal({ "cursor" => @messages.seq(@stranger).to_s, "messages" => [], "more" => false }, first)
    since = @messages.seq(@reply)
    found = @store.changes(since: since)
    assert_equal [ @photo, @dinner, @gone, @stranger ], found["messages"].map { |m| m["id"] }, "oldest first, no tapbacks or events"
    assert_equal first["cursor"], found["cursor"]
    paged = @store.changes(since: since, limit: 2)
    assert_equal [ [ @photo, @dinner ], true, @messages.seq(@dinner).to_s ], [ paged["messages"].map { |m| m["id"] }, paged["more"], paged["cursor"] ]
    assert_equal [ @photo, @gone, @stranger ], @store.changes(since: since, from_me: false)["messages"].map { |m| m["id"] }
    assert_equal [ @dinner ], @store.changes(since: since, from_me: true)["messages"].map { |m| m["id"] }
  end

  def test_a_scoped_key_sees_its_chats_and_people_and_nothing_else
    family = scope(chats: [ "chat100" ])
    assert_equal [ "any;+;chat100" ], @store.chats(scope: family).map { |c| c["id"] }
    assert_equal [ @dinner, @photo ], @store.messages(scope: family)["messages"].map { |m| m["id"] }
    assert_raises(Herald::Store::NotFound) { @store.message(@hello, scope: family) }
    assert_raises(Herald::Store::NotFound) { @store.messages(scope: family, chat: "any;-;+15551234567") }
    assert_equal [ @dinner ], @store.changes(scope: family, since: @messages.seq(@photo))["messages"].map { |m| m["id"] }
    assert_equal({ "path" => @messages.path, "messages" => 2, "chats" => 1, "latest_at" => "2026-10-06T16:05:00Z",
                   "latest_seq" => @messages.seq(@dinner).to_s }, @store.status(scope: family))

    ana = scope(handles: [ "555.123.4567" ])
    assert_equal [ "any;-;+15551234567" ], @store.chats(scope: ana).map { |c| c["id"] }, "her one-to-one chat, not the group"
  end

  def test_destination
    assert_equal "any;-;+15551234567", @store.destination(to: "(555) 123-4567")["chat"]
    assert_equal "any;+;chat100", @store.destination(chat: "any;+;chat100")["chat"]
    assert_equal({ "participant" => "+15550001111" }, @store.destination(to: "+15550001111"))
    assert_raises(Herald::Store::NotFound) { @store.destination(chat: "any;+;chat100", scope: scope(handles: [ "+15551234567" ])) }
  end

  def test_an_unreadable_database_is_unavailable_and_says_why
    store = Herald::Store.new(path: File.join(@dir, "missing", "chat.db"), contacts: Herald.contacts)
    error = assert_raises(Herald::Store::Unavailable) { store.chats }
    assert_match(/Full Disk Access/, error.message)
  end

  private

  def stub_const(owner, name, value)
    old = owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, old)
  end
end
