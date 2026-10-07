ENV["RACK_ENV"] = "test"
require "bundler/setup"
require "minitest/autorun"
require "rack/test"
require "tmpdir"
require_relative "../lib/herald"

# A Messages database of its own, in a temporary directory: the tables and
# columns herald reads, filled by the test. Dates are written the way
# Messages writes them, nanoseconds since 2001.
class FixtureMessages
  SCHEMA = <<~SQL.freeze
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE, style INTEGER, chat_identifier TEXT,
                       service_name TEXT, display_name TEXT);
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE, text TEXT, attributedBody BLOB,
                          handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER, date_read INTEGER DEFAULT 0,
                          date_delivered INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0,
                          item_type INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
                          associated_message_emoji TEXT, thread_originator_guid TEXT, date_edited INTEGER DEFAULT 0,
                          date_retracted INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
    CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, mime_type TEXT, uti TEXT,
                             transfer_name TEXT, total_bytes INTEGER, hide_attachment INTEGER DEFAULT 0);
    CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
  SQL

  attr_reader :path

  def self.apple(time)
    ((time.to_r - Herald::Store::APPLE_EPOCH) * 1_000_000_000).to_i
  end

  # What Messages keeps for most new messages instead of `text`.
  def self.attributed(text)
    bytes = text.b
    length = if bytes.bytesize < 0x80 then [ bytes.bytesize ].pack("C")
             elsif bytes.bytesize < 0x10000 then "\x81".b + [ bytes.bytesize ].pack("v")
             else "\x82".b + [ bytes.bytesize ].pack("V")
             end
    "\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x19NSMutableAttributedString\x00\x84\x84\x12NSAttributedString\x00" \
      "\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+".b + length + bytes + "\x86\x84\x02iI\x01\x05\x92".b
  end

  def initialize(dir)
    @path = File.join(dir, "chat.db")
    @db = SQLite3::Database.new(@path)
    @db.execute_batch(SCHEMA)
    @handles = {}
    @sequence = 0
  end

  def handle(id, service = "iMessage")
    @handles[[ id, service ]] ||= begin
      @db.execute("INSERT INTO handle (id, service) VALUES (?, ?)", [ id, service ])
      @db.last_insert_row_id
    end
  end

  def chat(guid, identifier:, handles: [], group: false, service: "iMessage", name: nil)
    @db.execute("INSERT INTO chat (guid, style, chat_identifier, service_name, display_name) VALUES (?, ?, ?, ?, ?)",
                [ guid, group ? 43 : 45, identifier, service, name ])
    rowid = @db.last_insert_row_id
    handles.each { |id| @db.execute("INSERT INTO chat_handle_join VALUES (?, ?)", [ rowid, handle(id, service) ]) }
    rowid
  end

  # Returns the message's guid.
  def message(chat, at:, text: nil, body: nil, from: nil, from_me: false, read: false, guid: nil, type: 0, target: nil,
              emoji: nil, item_type: 0, thread: nil, unsent: false, edited: false, delivered: nil, read_at: nil, attachments: [])
    guid ||= "M-#{@sequence += 1}"
    chat_rowid = @db.get_first_value("SELECT ROWID FROM chat WHERE guid = ?", [ chat ])
    service = @db.get_first_value("SELECT service_name FROM chat WHERE ROWID = ?", [ chat_rowid ])
    date = self.class.apple(at)
    @db.execute(<<~SQL, [ guid, text, body && SQLite3::Blob.new(self.class.attributed(body)), from ? handle(from, service) : 0, service, date,
      INSERT INTO message (guid, text, attributedBody, handle_id, service, date, is_from_me, is_read, associated_message_type,
                           associated_message_guid, associated_message_emoji, item_type, thread_originator_guid, date_retracted,
                           date_edited, date_delivered, date_read, cache_has_attachments)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
                          from_me ? 1 : 0, read ? 1 : 0, type, target && "p:0/#{target}", emoji, item_type, thread,
                          unsent ? date + 1 : 0, edited ? date + 1 : 0, delivered ? self.class.apple(delivered) : 0,
                          read_at ? self.class.apple(read_at) : 0, attachments.any? ? 1 : 0 ])
    rowid = @db.last_insert_row_id
    @db.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", [ chat_rowid, rowid, date ])
    attachments.each do |attachment|
      @db.execute("INSERT INTO attachment (filename, mime_type, uti, transfer_name, total_bytes, hide_attachment) VALUES (?, ?, ?, ?, ?, ?)",
                  [ "~/Library/Messages/Attachments/x/#{attachment[:name]}", attachment[:type], nil, attachment[:name], attachment[:size],
                    attachment[:hidden] ? 1 : 0 ])
      @db.execute("INSERT INTO message_attachment_join VALUES (?, ?)", [ rowid, @db.last_insert_row_id ])
    end
    guid
  end

  def seq(guid)
    @db.get_first_value("SELECT ROWID FROM message WHERE guid = ?", [ guid ])
  end
end

# Contacts, as an AddressBook database under a root of its own.
class FixtureContacts
  attr_reader :root

  def initialize(dir, people)
    @root = File.join(dir, "AddressBook")
    source = File.join(@root, "Sources", "ABC")
    FileUtils.mkdir_p(source)
    db = SQLite3::Database.new(File.join(source, "AddressBook-v22.abcddb"))
    db.execute_batch(<<~SQL)
      CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZORGANIZATION TEXT, ZNICKNAME TEXT);
      CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
      CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
    SQL
    people.each_with_index do |(name, handles), index|
      first, last = name.split(" ", 2)
      db.execute("INSERT INTO ZABCDRECORD VALUES (?, ?, ?, NULL, NULL)", [ index + 1, first, last ])
      Array(handles).each do |handle|
        table, column = handle.include?("@") ? %w[ZABCDEMAILADDRESS ZADDRESS] : %w[ZABCDPHONENUMBER ZFULLNUMBER]
        db.execute("INSERT INTO #{table} (ZOWNER, #{column}) VALUES (?, ?)", [ index + 1, handle ])
      end
    end
    db.close
  end
end

# Stands in for Messages' `send`: records what it was asked, and (unless
# told to be slow) writes the sent message into the fixture the way
# Messages would, so herald can find it.
class FakeSender
  attr_reader :calls

  def initialize(fixture, answer: :appear)
    @fixture = fixture
    @answer = answer
    @calls = []
  end

  def send_text(text, destination)
    @calls << [ text, destination ]
    raise @answer if @answer.is_a?(Exception)
    return true unless @answer == :appear

    chat = destination["chat"] || "any;-;#{destination['participant']}"
    @fixture.chat(chat, identifier: destination["participant"], handles: [ destination["participant"] ]) if destination["participant"]
    @fixture.message(chat, at: Time.now, body: text, from_me: true)
    true
  end
end

# The household's messages, as the tests use them. Times are fixed, in UTC.
module Household
  T0 = Time.utc(2026, 10, 6, 16, 0, 0)

  def build_household
    @dir = Dir.mktmpdir("herald")
    @messages = FixtureMessages.new(@dir)
    @contacts = FixtureContacts.new(@dir, { "Ana Ruiz" => [ "(555) 123-4567", "ana@example.com" ], "Ben Ode" => "+1 555 222 3333" })
    Herald.contacts = Herald::Contacts.new(root: @contacts.root)
    Herald.store = Herald::Store.new(path: @messages.path, contacts: Herald.contacts)

    @messages.chat("any;-;+15551234567", identifier: "+15551234567", handles: [ "+15551234567" ])
    @messages.chat("any;-;+15552223333", identifier: "+15552223333", handles: [ "+15552223333" ], service: "SMS")
    @messages.chat("any;+;chat100", identifier: "chat100", handles: [ "+15551234567", "+15552223333" ], group: true, name: "Family")
    @messages.chat("any;-;+15559990000", identifier: "+15559990000", handles: [ "+15559990000" ])

    @hello = @messages.message("any;-;+15551234567", at: T0, text: "Hello there", from: "+15551234567", read: true)
    @late = @messages.message("any;-;+15551234567", at: T0 + 60, body: "Running 10 late, save me a seat", from: "+15551234567")
    @reply = @messages.message("any;-;+15551234567", at: T0 + 120, body: "No problem", from_me: true, delivered: T0 + 121,
                                                     read_at: T0 + 180, thread: @late)
    @photo = @messages.message("any;+;chat100", at: T0 + 200, body: "￼", from: "+15552223333",
                                                attachments: [ { name: "IMG_1.HEIC", type: "image/heic", size: 1200 },
                                                               { name: "plugin.pluginPayloadAttachment", type: nil, size: 3, hidden: true } ])
    @dinner = @messages.message("any;+;chat100", at: T0 + 300, body: "Dinner at 7?", from_me: true)
    @messages.message("any;+;chat100", at: T0 + 310, from: "+15551234567", type: 2000, target: @dinner)                # loved
    @messages.message("any;+;chat100", at: T0 + 320, from: "+15552223333", type: 2001, target: @dinner)                # liked
    @messages.message("any;+;chat100", at: T0 + 330, from: "+15552223333", type: 3001, target: @dinner)                # ...taken back
    @messages.message("any;+;chat100", at: T0 + 340, from_me: true, type: 2006, emoji: "🍝", target: @dinner)
    @messages.message("any;+;chat100", at: T0 + 350, item_type: 2, from: "+15552223333")                               # renamed the group
    @gone = @messages.message("any;-;+15552223333", at: T0 + 400, body: "oops", from: "+15552223333", unsent: true)
    @stranger = @messages.message("any;-;+15559990000", at: T0 + 500, text: "Your code is 123456", from: "+15559990000")
  end

  def teardown_household
    FileUtils.remove_entry(@dir) if @dir
  end
end
