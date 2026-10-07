require "json"
require "roda"
require "time"

module Herald
  # The HTTP face (API.md is the contract). Routes check the key's
  # permission, turn the query into arguments for the Store (reads) or the
  # Sender (sends), and write every send to the audit log. What a scoped key
  # may see is decided in Store, on every query. /v1/keys is the exception:
  # it takes HERALD_ADMIN_TOKEN, not a key.
  class App < Roda
    API_DOC = File.expand_path("../../API.md", __dir__)
    STATUS = {
      "bad_request" => 400, "unauthorized" => 401, "forbidden" => 403, "not_found" => 404,
      "idempotency_mismatch" => 409, "invalid" => 422, "messages_unavailable" => 503
    }.freeze
    PARAMS = {
      "chats" => %w[q active_after limit],
      "messages" => %w[chat from q after before unread limit],
      "changes" => %w[since from_me limit]
    }.freeze
    SEND_FIELDS = %w[chat to text].freeze
    KEY_FIELDS = %w[permissions scope].freeze
    MAX_TEXT = 20_000
    IDEMPOTENCY = Idempotency.new

    # A refusal herald makes itself.
    class Refusal < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    plugin :all_verbs
    plugin :halt
    plugin :request_headers
    plugin :error_handler do |error|
      case error
      when Refusal then problem(error.code, error.message)
      when Store::NotFound then problem("not_found", error.message, "kind" => error.kind)
      when Store::Unavailable, Sender::Unavailable then problem("messages_unavailable", error.message)
      when Sender::Refused then problem("invalid", error.message)
      when Idempotency::Mismatch then problem("idempotency_mismatch", error.message)
      else
        warn "herald: #{error.class}: #{error.message}\n#{error.backtrace&.first(8)&.join("\n")}"
        response.status = 500
        json("error" => { "code" => "internal", "message" => "herald tripped over itself; the server log has the details" })
      end
    end
    plugin :not_found do
      json("error" => { "code" => "not_found", "message" => "no such endpoint; GET /v1/docs describes the API" })
    end

    route do |r|
      r.get("health") { json("ok" => true, "version" => VERSION) }

      r.on "v1" do
        r.on "keys" do
          admin!
          r.get(true) { json("keys" => Herald.keys.all.map(&:admin_json)) }
          r.is String do |name|
            name = unescape(name)
            r.get { json(existing_key(name).admin_json) }
            r.patch { change_key(name) }
          end
        end

        @key = Herald.keys.authenticate(bearer)
        raise Refusal.new("unauthorized", "send a herald key as Authorization: Bearer <key>") if @key.nil?

        r.get "docs" do
          response["Content-Type"] = "text/markdown; charset=utf-8"
          File.read(API_DOC)
        end

        r.get "status" do
          permit!("read")
          json("herald" => VERSION, "macos" => Herald.macos, "database" => Herald.store.status(scope: scope),
               "contacts" => (people = Herald.contacts.count) && { "people" => people },
               "key" => @key.as_json, "now" => Time.now.utc.iso8601)
        end

        r.on "chats" do
          r.get(true) do
            args = params("chats")
            chats = Herald.store.chats(scope: scope, q: words(args["q"]), active_after: time(args, "active_after"),
                                       limit: limit(args, 50))
            json("chats" => chats, "count" => chats.size)
          end
          r.get(String) { |id| permit!("read") && json(Herald.store.chat(unescape(id), scope: scope)) }
        end

        r.on "messages" do
          r.is do
            r.get do
              args = params("messages")
              json(Herald.store.messages(scope: scope, chat: present(args["chat"]), from: present(args["from"]), q: words(args["q"]),
                                         after: time(args, "after"), before: time(args, "before"),
                                         unread: boolean(args, "unread"), limit: limit(args, 50)))
            end
            r.post { send_message(body) }
          end
          r.get(String) { |id| permit!("read") && json(Herald.store.message(unescape(id), scope: scope)) }
        end

        r.get "changes" do
          args = params("changes")
          json(Herald.store.changes(scope: scope, since: seq(args["since"]), from_me: boolean(args, "from_me"), limit: limit(args, 100)))
        end
      end
    end

    private

    def bearer
      request.headers["Authorization"].to_s[/\ABearer\s+(\S+)\z/i, 1]
    end

    def scope
      @key.confinement
    end

    def permit!(permission)
      return true if @key.may?(permission)

      raise Refusal.new("forbidden", "the key #{@key.name.inspect} lacks the #{permission} permission")
    end

    # --- keys (admin) ---

    # HERALD_ADMIN_TOKEN, compared in constant time. A key from keys.json is
    # not enough, whatever it may do.
    def admin!
      token = Herald.admin_token
      return if token && bearer && Rack::Utils.secure_compare(bearer, token)

      raise Refusal.new("unauthorized", "keys are managed with HERALD_ADMIN_TOKEN as Authorization: Bearer <token>#{' (it is not set on this herald)' unless token}")
    end

    # The X-Admin-Actor header, for the audit log: one token, many people.
    def admin_actor
      request.headers["X-Admin-Actor"].to_s.strip[0, 100].then { |actor| actor.empty? ? "admin" : actor }
    end

    def existing_key(name)
      Herald.keys.find(name) or raise Store::NotFound.new("key", "no key named #{name}")
    end

    # Permissions, scope, or both, keeping the token. Every attempt is
    # audited, refused or not.
    def change_key(name)
      fields = nil
      fields = body
      unknown = fields.keys - KEY_FIELDS
      raise Refusal.new("bad_request", "unknown field#{'s' if unknown.size > 1} #{unknown.join(', ')} (known: #{KEY_FIELDS.join(', ')})") if unknown.any?
      raise Refusal.new("bad_request", "give permissions, scope, or both") if fields.empty?

      changes = fields.transform_keys(&:to_sym)
      before, after = Herald.keys.change(name, **changes)
      Herald.audit.record(key: name, admin: admin_actor, op: "keys.change", args: fields, outcome: "changed",
                          before: before.as_json, after: after.as_json)
      json(after.admin_json)
    rescue Keys::Missing => e
      Herald.audit.record(key: name, admin: admin_actor, op: "keys.change", args: fields, outcome: "refused", error: e.message)
      raise Store::NotFound.new("key", e.message)
    rescue Keys::Error, Refusal => e
      Herald.audit.record(key: name, admin: admin_actor, op: "keys.change", args: fields, outcome: "refused", error: e.message)
      raise e.is_a?(Refusal) ? e : Refusal.new("invalid", e.message)
    end

    # --- sending ---

    def send_message(fields)
      permit!("send")
      unknown = fields.keys - SEND_FIELDS
      raise Refusal.new("bad_request", "unknown field#{'s' if unknown.size > 1} #{unknown.join(', ')} (known: #{SEND_FIELDS.join(', ')})") if unknown.any?

      text, chat, to = fields.values_at("text", "chat", "to")
      [ chat, to ].compact.each { |value| raise Refusal.new("bad_request", "chat and to are strings") unless value.is_a?(String) }
      raise Refusal.new("invalid", "text is required: what the message says") unless text.is_a?(String) && !text.strip.empty?
      raise Refusal.new("invalid", "text is at most #{MAX_TEXT} characters") if text.length > MAX_TEXT
      raise Refusal.new("invalid", "give chat (an existing chat's id) or to (a phone number or address), not both") if present(chat) && present(to)
      raise Refusal.new("invalid", "give chat (an existing chat's id) or to (a phone number or address)") unless present(chat) || present(to)
      raise Refusal.new("forbidden", "the key #{@key.name.inspect} may not send to #{to.inspect}") if present(to) && scope && !scope.handle?(to)

      args = { "chat" => present(chat), "to" => present(to), "text" => text }.compact
      fingerprint = "POST /v1/messages\n#{JSON.generate(args)}"
      status, payload = IDEMPOTENCY.once(@key.name, request.headers["Idempotency-Key"], fingerprint) { deliver(args) }
      response.status = status
      json(payload)
    end

    # Ask Messages to send, then watch for the message to appear.
    def deliver(args)
      destination = Herald.store.destination(scope: scope, chat: args["chat"], to: args["to"])
      before = Herald.store.latest_seq
      begin
        Herald.sender.send_text(args["text"], destination)
      rescue Sender::Refused, Sender::Unavailable => e
        Herald.audit.record(key: @key.name, op: "messages.send", args: args, outcome: "failed", error: e.message)
        raise
      end
      message = wait_for(before, args["text"], destination, args["to"])
      Herald.audit.record(key: @key.name, op: "messages.send", args: args, outcome: message ? "sent" : "pending", ids: message && [ message["id"] ])
      return [ 201, { "message" => message } ] if message

      [ 202, { "pending" => true, "chat_id" => destination["chat"] } ]
    end

    def wait_for(before, text, destination, to)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Herald.send_wait
      loop do
        found = Herald.store.sent(after: before, text: text, chat_rowid: destination["rowid"], to: destination["rowid"] ? nil : to)
        return found if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.25
      end
    end

    # --- what comes in ---

    # The query, refusing anything this endpoint does not take. Reading
    # needs `read`, so it is checked here, before anything is looked at.
    def params(endpoint)
      permit!("read")
      query = Rack::Utils.parse_query(request.query_string)
      unknown = query.keys - PARAMS.fetch(endpoint)
      raise Refusal.new("bad_request", "unknown parameter#{'s' if unknown.size > 1} #{unknown.join(', ')} (known: #{PARAMS.fetch(endpoint).join(', ')})") if unknown.any?

      repeated = query.select { |_, value| value.is_a?(Array) }.keys
      raise Refusal.new("bad_request", "#{repeated.join(', ')} given more than once") if repeated.any?

      query
    end

    def body
      raw = request.body&.read.to_s
      return {} if raw.strip.empty?

      parsed = JSON.parse(raw)
      raise Refusal.new("bad_request", "the request body must be a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise Refusal.new("bad_request", "the request body is not valid JSON: #{e.message[0, 120]}")
    end

    # A time with its offset, or a bare date: midnight on this Mac.
    def time(args, name)
      value = present(args[name]) or return nil
      if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        year, month, day = value.split("-").map(&:to_i)
        return Time.local(year, month, day)
      end
      raise ArgumentError unless value.match?(/T.*(Z|[+-]\d\d:?\d\d)\z/i)

      Time.iso8601(value)
    rescue ArgumentError
      raise Refusal.new("bad_request", "#{name} must be a date like 2026-10-06 or a time with its offset like 2026-10-06T15:00:00Z, got #{value.inspect}")
    end

    def limit(args, default)
      return default if args["limit"].nil?

      value = Integer(args["limit"], 10)
      raise ArgumentError unless value.between?(1, 500)

      value
    rescue ArgumentError, TypeError
      raise Refusal.new("bad_request", "limit is a whole number from 1 to 500, got #{args['limit'].inspect}")
    end

    def boolean(args, name)
      case args[name]
      when nil then nil
      when "true" then true
      when "false" then false
      else raise Refusal.new("bad_request", "#{name} is true or false, got #{args[name].inspect}")
      end
    end

    def seq(value)
      return nil if value.nil?
      raise Refusal.new("bad_request", "since is the cursor the last /v1/changes returned, got #{value.inspect}") unless value.match?(/\A\d+\z/)

      value.to_i
    end

    def words(value)
      value = present(value)
      value && !value.split.empty? ? value : nil
    end

    def present(value)
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    # Chat ids carry semicolons and plus signs; a plus in a path is a plus.
    # The segment arrives as bytes, and SQLite would bind bytes as a blob,
    # which equals no id: it is text.
    def unescape(segment)
      Rack::Utils.unescape_path(segment).dup.force_encoding(Encoding::UTF_8)
    end

    def json(payload)
      response["Content-Type"] = "application/json"
      JSON.generate(payload)
    end

    def problem(code, message, details = {})
      response.status = STATUS.fetch(code, 422)
      json("error" => { "code" => code, "message" => message }.merge(details.compact))
    end
  end
end
