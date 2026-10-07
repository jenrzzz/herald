require_relative "test_helper"
require "erb"

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include Household

  def app
    Herald::App.freeze.app
  end

  def setup
    build_household
    ENV["HERALD_SEND_WAIT"] = "1"
    Herald.keys = Herald::Keys.new(File.join(@dir, "keys.json"))
    Herald.audit = Herald::Audit.new(File.join(@dir, "audit.jsonl"))
    Herald.sender = @sender = FakeSender.new(@messages)
    @admin = Herald.keys.add("hob", permissions: %w[read send])
    @reader = Herald.keys.add("reader", permissions: %w[read])
    @family = Herald.keys.add("family", permissions: %w[read send], scope: { "chats" => [ "any;+;chat100" ], "handles" => [ "+15551234567" ] })
  end

  def teardown
    ENV.delete("HERALD_SEND_WAIT")
    teardown_household
  end

  def call(verb, path, payload = nil, token: @admin, headers: {})
    env = { "CONTENT_TYPE" => "application/json" }.merge(headers)
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    send(verb, path, payload.nil? || payload.is_a?(String) ? payload : JSON.generate(payload), env)
    last_response.content_type.to_s.include?("json") ? JSON.parse(last_response.body) : last_response.body
  end

  def audit
    path = File.join(@dir, "audit.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def escaped(id)
    ERB::Util.url_encode(id)
  end

  def test_health_needs_no_key
    assert_equal({ "ok" => true, "version" => Herald::VERSION }, call(:get, "/health", token: nil))
  end

  def test_everything_else_needs_a_key
    [ nil, "hrd_unknown" ].each do |token|
      assert_equal "unauthorized", call(:get, "/v1/chats", token: token).dig("error", "code")
      assert_equal 401, last_response.status
    end
  end

  def test_docs
    assert_match(/\A# herald API/, call(:get, "/v1/docs"))
  end

  def test_status
    status = call(:get, "/v1/status")
    assert_equal [ Herald::VERSION, 7, 4, { "people" => 2 } ], [ status["herald"], status.dig("database", "messages"),
                                                                 status.dig("database", "chats"), status["contacts"] ]
    assert_equal({ "name" => "hob", "permissions" => %w[read send], "scope" => nil }, status["key"])
  end

  def test_chats_and_a_chat_by_its_escaped_id
    assert_equal 4, call(:get, "/v1/chats")["count"]
    assert_equal [ "Family" ], call(:get, "/v1/chats?q=family")["chats"].map { |c| c["name"] }
    assert_equal "Family", call(:get, "/v1/chats/#{escaped('any;+;chat100')}")["name"]
    assert_equal "Ana Ruiz", call(:get, "/v1/chats/any;-;+15551234567")["name"], "a plus in a path is a plus"
    assert_equal [ 404, "chat" ], [ last_response.status, nil ].then { call(:get, "/v1/chats/nope").then { |e| [ last_response.status, e.dig("error", "kind") ] } }
  end

  def test_messages_and_a_message
    page = call(:get, "/v1/messages?chat=#{escaped('any;-;+15551234567')}&limit=2")
    assert_equal [ [ @reply, @late ], true ], [ page["messages"].map { |m| m["id"] }, page["truncated"] ]
    assert_equal [ @late ], call(:get, "/v1/messages?q=seat&from=ana")["messages"].map { |m| m["id"] }
    assert_equal [ @dinner, @photo ], call(:get, "/v1/messages?after=2026-10-06T16:03:00Z&before=2026-10-06T09:06:00-07:00")["messages"].map { |m| m["id"] }
    assert_equal "Dinner at 7?", call(:get, "/v1/messages/#{@dinner}")["text"]
    call(:get, "/v1/messages/nope")
    assert_equal 404, last_response.status
  end

  def test_what_comes_in_is_checked
    [ "/v1/messages?chats=x", "/v1/messages?after=2026-10-06T16:00:00", "/v1/messages?limit=0", "/v1/messages?limit=501",
      "/v1/messages?unread=yes", "/v1/changes?since=abc", "/v1/chats?q=a&q=b" ].each do |path|
      error = call(:get, path)["error"]
      assert_equal [ 400, "bad_request" ], [ last_response.status, error["code"] ], path
    end
    assert_match(/unknown parameter chats \(known: chat, from/, call(:get, "/v1/messages?chats=x").dig("error", "message"))
    assert_equal 7, call(:get, "/v1/messages?after=2026-10-01")["count"], "a bare date is fine"
  end

  def test_changes
    first = call(:get, "/v1/changes")
    assert_equal [], first["messages"]
    @messages.message("any;-;+15551234567", at: Time.now, body: "One more thing", from: "+15551234567")
    found = call(:get, "/v1/changes?since=#{first['cursor']}&from_me=false")
    assert_equal [ "One more thing" ], found["messages"].map { |m| m["text"] }
    assert_operator found["cursor"].to_i, :>, first["cursor"].to_i
  end

  def test_reading_needs_read_and_sending_needs_send
    sender_only = Herald.keys.add("sender-only", permissions: %w[send])
    assert_equal "forbidden", call(:get, "/v1/messages", token: sender_only).dig("error", "code")
    assert_equal "forbidden", call(:get, "/v1/chats/any;-;+15551234567", token: sender_only).dig("error", "code")
    assert_equal "forbidden", call(:post, "/v1/messages", { chat: "any;+;chat100", text: "hi" }, token: @reader).dig("error", "code")
    assert_equal 403, last_response.status
    assert_empty @sender.calls
  end

  def test_send_to_a_chat_waits_for_the_message_and_audits_its_length
    sent = call(:post, "/v1/messages", { chat: "any;+;chat100", text: "On my way" })
    assert_equal 201, last_response.status
    assert_equal [ "On my way", true, "any;+;chat100" ], sent["message"].values_at("text", "from_me", "chat_id")
    assert_equal [ [ "On my way", { "chat" => "any;+;chat100", "rowid" => 3 } ] ], @sender.calls
    entry = audit.last
    assert_equal [ "hob", "messages.send", "sent", { "chat" => "any;+;chat100", "text" => "(9 characters)" }, [ sent["message"]["id"] ] ],
                 entry.values_at("key", "op", "outcome", "args", "ids")
  end

  def test_send_to_a_person_uses_their_chat_or_starts_one
    call(:post, "/v1/messages", { to: "555-123-4567", text: "Hi Ana" })
    assert_equal 201, last_response.status
    assert_equal "any;-;+15551234567", @sender.calls.last[1]["chat"]

    sent = call(:post, "/v1/messages", { to: "+15550001111", text: "Hello, stranger" })
    assert_equal 201, last_response.status
    assert_equal({ "participant" => "+15550001111" }, @sender.calls.last[1])
    assert_equal "Hello, stranger", sent.dig("message", "text")
  end

  def test_a_send_that_does_not_appear_in_time_is_pending
    Herald.sender = FakeSender.new(@messages, answer: :vanish)
    ENV["HERALD_SEND_WAIT"] = "0.3"
    pending = call(:post, "/v1/messages", { chat: "any;+;chat100", text: "Into the void" })
    assert_equal [ 202, { "pending" => true, "chat_id" => "any;+;chat100" } ], [ last_response.status, pending ]
    assert_equal "pending", audit.last["outcome"]
  end

  def test_send_is_checked_before_messages_is_asked
    { { text: "hi" } => "invalid", { chat: "any;+;chat100", to: "+15551234567", text: "hi" } => "invalid",
      { chat: "any;+;chat100", text: "  " } => "invalid", { chat: "any;+;chat100", text: "x" * 20_001 } => "invalid",
      { chat: "any;+;chat100", text: "hi", subject: "x" } => "bad_request", { chat: 5, text: "hi" } => "bad_request" }.each do |body, code|
      assert_equal code, call(:post, "/v1/messages", body).dig("error", "code"), body.inspect
    end
    assert_equal "bad_request", call(:post, "/v1/messages", "not json").dig("error", "code")
    assert_equal [ 404, "chat" ], [ call(:post, "/v1/messages", { chat: "any;+;nope", text: "hi" }).dig("error", "kind") ].unshift(last_response.status)
    assert_empty @sender.calls
  end

  def test_messages_refusing_and_messages_unavailable
    Herald.sender = FakeSender.new(@messages, answer: Herald::Sender::Refused.new("Messages could not find whom to send to"))
    assert_equal [ "invalid", 422 ], [ call(:post, "/v1/messages", { to: "+15550001111", text: "hi" }).dig("error", "code"), last_response.status ]
    Herald.sender = FakeSender.new(@messages, answer: Herald::Sender::Unavailable.new("macOS has not allowed herald to control Messages"))
    assert_equal [ "messages_unavailable", 503 ], [ call(:post, "/v1/messages", { to: "+15550001111", text: "hi" }).dig("error", "code"), last_response.status ]
    assert_equal %w[failed failed], audit.map { |entry| entry["outcome"] }

    Herald.store = Herald::Store.new(path: File.join(@dir, "missing", "chat.db"), contacts: Herald.contacts)
    assert_equal [ "messages_unavailable", 503 ], [ call(:get, "/v1/chats").dig("error", "code"), last_response.status ]
  end

  def test_idempotent_sends
    headers = { "HTTP_IDEMPOTENCY_KEY" => "abc" }
    first = call(:post, "/v1/messages", { chat: "any;+;chat100", text: "Once" }, headers: headers)
    again = call(:post, "/v1/messages", { chat: "any;+;chat100", text: "Once" }, headers: headers)
    assert_equal [ first, 201, 1 ], [ again, last_response.status, @sender.calls.size ]
    assert_equal "idempotency_mismatch", call(:post, "/v1/messages", { chat: "any;+;chat100", text: "Twice" }, headers: headers).dig("error", "code")
  end

  def test_a_scoped_key
    assert_equal %w[any;+;chat100 any;-;+15551234567], call(:get, "/v1/chats", token: @family)["chats"].map { |c| c["id"] }
    assert_equal 404, last_response.status.then { call(:get, "/v1/messages/#{@stranger}", token: @family) && last_response.status }
    assert_equal 404, call(:get, "/v1/messages?chat=#{escaped('any;-;+15559990000')}", token: @family).then { last_response.status }
    refute_includes call(:get, "/v1/messages?limit=500", token: @family)["messages"].map { |m| m["id"] }, @stranger

    call(:post, "/v1/messages", { to: "+15559990000", text: "hi" }, token: @family)
    assert_equal 403, last_response.status
    call(:post, "/v1/messages", { chat: "any;-;+15559990000", text: "hi" }, token: @family)
    assert_equal 404, last_response.status
    assert_empty @sender.calls
    call(:post, "/v1/messages", { to: "+1 (555) 123-4567", text: "hi" }, token: @family)
    assert_equal 201, last_response.status
  end

  def test_keys_take_the_admin_token_and_nothing_else
    [ nil, "wrong", @admin ].each do |token|
      ENV["HERALD_ADMIN_TOKEN"] = "admin-secret"
      assert_equal [ "unauthorized", 401 ], [ call(:get, "/v1/keys", token: token).dig("error", "code"), last_response.status ]
      call(:patch, "/v1/keys/family", { permissions: %w[read] }, token: token)
      assert_equal 401, last_response.status
    end
    ENV.delete("HERALD_ADMIN_TOKEN")
    assert_match(/not set/, call(:get, "/v1/keys", token: "").dig("error", "message"))
    assert_equal %w[read send], Herald.keys.find("family").permissions
    assert_empty audit
  ensure
    ENV.delete("HERALD_ADMIN_TOKEN")
  end

  def test_an_admin_reads_and_changes_a_key_without_rotating_it
    ENV["HERALD_ADMIN_TOKEN"] = "admin-secret"
    keys = call(:get, "/v1/keys", token: "admin-secret")["keys"]
    assert_equal %w[hob reader family], keys.map { |k| k["name"] }
    refute keys.any? { |k| k.key?("digest") }, "the digest never leaves"
    assert_equal({ "chats" => [ "any;+;chat100" ], "handles" => [ "+15551234567" ] }, call(:get, "/v1/keys/family", token: "admin-secret")["scope"])
    missing = call(:get, "/v1/keys/nope", token: "admin-secret")
    assert_equal [ 404, "key" ], [ last_response.status, missing.dig("error", "kind") ]

    changed = call(:patch, "/v1/keys/family", { permissions: %w[read], scope: { chats: [ "any;+;chat100" ] } },
                   token: "admin-secret", headers: { "HTTP_X_ADMIN_ACTOR" => "jenner" })
    assert_equal 200, last_response.status
    assert_equal [ %w[read], { "chats" => [ "any;+;chat100" ] } ], changed.values_at("permissions", "scope")
    refute_nil changed["updated_at"]

    assert_equal "family", Herald.keys.authenticate(@family).name, "the token still works"
    call(:post, "/v1/messages", { chat: "any;+;chat100", text: "hi" }, token: @family)
    assert_equal 403, last_response.status, "and it may no longer send"
    assert_equal [ "any;+;chat100" ], call(:get, "/v1/chats", token: @family)["chats"].map { |c| c["id"] }

    entry = audit.last
    assert_equal [ "keys.change", "family", "jenner", "changed" ], entry.values_at("op", "key", "admin", "outcome")
    assert_equal %w[read send], entry.dig("before", "permissions")
    assert_equal %w[read], entry.dig("after", "permissions")

    call(:patch, "/v1/keys/family", { scope: nil }, token: "admin-secret")
    assert_equal [ 200, nil, %w[read] ], [ last_response.status, Herald.keys.find("family").scope, Herald.keys.find("family").permissions ]
  ensure
    ENV.delete("HERALD_ADMIN_TOKEN")
  end

  def test_a_refused_key_change_changes_nothing_and_is_audited
    ENV["HERALD_ADMIN_TOKEN"] = "admin-secret"
    [
      [ { permissions: %w[write] }, 422 ],
      [ { permissions: [] }, 422 ],
      [ { permissions: "read" }, 422 ],
      [ { scope: { chats: [] } }, 422 ],
      [ { scope: { handles: [ 7 ] } }, 422 ],
      [ { domains: [ "x" ] }, 400 ],
      [ {}, 400 ],
      [ "{", 400 ]
    ].each do |payload, status|
      call(:patch, "/v1/keys/family", payload, token: "admin-secret")
      assert_equal status, last_response.status, payload.inspect
    end
    call(:patch, "/v1/keys/nope", { permissions: %w[read] }, token: "admin-secret")
    assert_equal 404, last_response.status

    family = Herald.keys.find("family")
    assert_equal [ %w[read send], [ "any;+;chat100" ] ], [ family.permissions, family.scope["chats"] ]
    assert_equal [ "refused" ] * 9, audit.map { |entry| entry["outcome"] }
  ensure
    ENV.delete("HERALD_ADMIN_TOKEN")
  end
end
