# rake live: the read side of the API against the real Messages database
# and Contacts on this Mac, through the app as a client would call it. It
# never sends, and it prints counts and shapes, never what a message says.
require "bundler/setup"
require "erb"
require "json"
require "rack/mock"
require "tmpdir"
require_relative "../../lib/herald"

failures = []
check = lambda do |what, ok|
  puts "#{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

Dir.mktmpdir("herald-live") do |dir|
  Herald.keys = Herald::Keys.new(File.join(dir, "keys.json"))
  token = Herald.keys.add("live", permissions: %w[read])
  app = Rack::MockRequest.new(Herald::App.freeze.app)
  get = lambda do |path|
    response = app.get(path, "HTTP_AUTHORIZATION" => "Bearer #{token}")
    [ response.status, JSON.parse(response.body) ]
  end

  status, body = get.call("/v1/status")
  check.call("status answers (#{body.dig('error', 'message') || "#{body.dig('database', 'messages')} messages"})", status == 200)
  abort "herald cannot read Messages here; nothing more to try" unless status == 200
  check.call("contacts are read (#{body.dig('contacts', 'people').inspect} people)", !body["contacts"].nil?)

  _, chats = get.call("/v1/chats?limit=20")
  check.call("chats come back newest first", chats["chats"].map { |c| c["last_message_at"] } == chats["chats"].map { |c| c["last_message_at"] }.sort.reverse)
  chat = chats["chats"].first
  status, one = get.call("/v1/chats/#{ERB::Util.url_encode(chat['id'])}")
  check.call("a chat by its escaped id", status == 200 && one["id"] == chat["id"])

  _, page = get.call("/v1/messages?limit=100")
  messages = page["messages"]
  check.call("messages come back, most with text (#{messages.count { |m| m['text'] }}/#{messages.size})",
             messages.size == 100 && messages.count { |m| m["text"] } > 50)
  check.call("no tapback is a message", messages.none? { |m| m["text"].to_s.match?(/\A(Loved|Liked|Laughed at|Emphasized) “/) })
  status, single = get.call("/v1/messages/#{messages.first['id']}")
  check.call("a message by id is the same message", status == 200 && single == messages.first)

  _, mine = get.call("/v1/messages?from=me&limit=20")
  check.call("from=me is only mine", mine["messages"].all? { |m| m["from_me"] })
  word = messages.filter_map { |m| m["text"]&.split&.find { |w| w.match?(/\A[a-zA-Z]{5,}\z/) } }.first
  if word
    _, found = get.call("/v1/messages?q=#{ERB::Util.url_encode(word)}&limit=5")
    check.call("a word from a recent message finds it", found["messages"].any? { |m| m["text"].to_s.downcase.include?(word.downcase) })
  end

  _, first = get.call("/v1/changes")
  _, since = get.call("/v1/changes?since=#{first['cursor'].to_i - 20}&limit=5")
  check.call("changes: oldest first, with more", since["messages"].map { |m| m["seq"] } == since["messages"].map { |m| m["seq"] }.sort)

  scoped = Herald.keys.add("live-scoped", permissions: %w[read], scope: { "chats" => [ chat["id"] ] })
  response = app.get("/v1/messages?limit=50", "HTTP_AUTHORIZATION" => "Bearer #{scoped}")
  check.call("a scoped key sees only its chat", JSON.parse(response.body)["messages"].all? { |m| m["chat_id"] == chat["id"] })
end

puts failures.empty? ? "all good" : "#{failures.size} failed"
exit(failures.empty? ? 0 : 1)
