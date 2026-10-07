require "sqlite3"
require "set"
require "time"

module Herald
  # The Messages database (~/Library/Messages/chat.db), read-only. Messages
  # owns the file and writes it constantly; herald opens it with SQLite's
  # read-only flag for each request and never holds it open, so nothing here
  # can change a message or stand in the app's way.
  #
  # What the tables mean, as far as herald needs them:
  #
  #   chat     a conversation; `guid` is the id (any;-;+15551234567), style
  #            43 a group and 45 one-to-one
  #   handle   a phone number or address, once per service
  #   message  one row per message, tapback, and group event. `date` counts
  #            nanoseconds from 2001-01-01 (seconds, on databases from before
  #            2017). `text` is null for most newer messages, whose words are
  #            only in `attributedBody` (Typedstream). A tapback is a row
  #            with associated_message_type 2000-2007 (3000-3007 takes one
  #            back) pointing at its message by `associated_message_guid`
  #            ("p:0/<guid>", "bp:<guid>"); a group event has item_type > 0
  #   chat_message_join, chat_handle_join, message_attachment_join, attachment
  #
  # A scope (Keys) is applied here: a chat outside it is not found, and its
  # messages are never selected.
  class Store
    APPLE_EPOCH = 978_307_200
    REACTIONS = %w[loved liked disliked laughed emphasized questioned emoji sticker].freeze
    SEARCH_LIMIT = 20_000
    BATCH = 500
    OBJECT_REPLACEMENT = "\uFFFC".freeze
    # A message, not a tapback or a group event.
    MESSAGE = "m.item_type = 0 AND (m.associated_message_type < 2000 OR m.associated_message_type > 3999)".freeze
    COLUMNS = <<~SQL.freeze
      m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.date_read, m.date_delivered, m.is_from_me, m.is_read,
      m.service, m.thread_originator_guid, m.date_edited, m.date_retracted, m.cache_has_attachments, j.chat_id, c.guid, h.id
    SQL
    FROM = <<~SQL.freeze
      FROM message m
      JOIN chat_message_join j ON j.message_id = m.ROWID
      JOIN chat c ON c.ROWID = j.chat_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
    SQL

    Row = Struct.new(:rowid, :guid, :text, :body, :date, :date_read, :date_delivered, :from_me, :is_read, :service,
                     :thread, :date_edited, :date_retracted, :has_attachments, :chat_rowid, :chat_guid, :handle)

    class NotFound < StandardError
      attr_reader :kind

      def initialize(kind, message)
        @kind = kind
        super(message)
      end
    end

    # The database could not be read at all.
    class Unavailable < StandardError; end

    attr_reader :path

    def initialize(path:, contacts:)
      @path = path
      @contacts = contacts
    end

    # --- chats ---

    def chats(scope: nil, q: nil, active_after: nil, limit: 50)
      read do |db|
        list = all_chats(db).select { |chat| visible?(chat, scope) }
        list = list.select { |chat| chat[:last_date] >= apple(db, active_after) } if active_after
        pairs = list.map { |chat| [ chat[:rowid], chat_shape(chat) ] }
        if q
          words = q.downcase.split
          pairs = pairs.select do |_, chat|
            haystack = [ chat["name"], chat["identifier"], *chat["participants"].flat_map(&:values) ].compact.join(" ").downcase
            words.all? { |word| haystack.include?(word) }
          end
        end
        pairs = pairs.first(limit)
        counts = unread_counts(db, pairs.map(&:first))
        pairs.map { |rowid, chat| chat.merge("unread" => counts.fetch(rowid, 0)) }
      end
    end

    def chat(id, scope: nil)
      read do |db|
        found = find_chat(db, id, scope)
        chat_shape(found).merge("unread" => unread_counts(db, [ found[:rowid] ]).fetch(found[:rowid], 0))
      end
    end

    # --- messages ---

    # -> { "messages", "count", "truncated", "searched_back_to" }, newest first.
    def messages(scope: nil, chat: nil, from: nil, q: nil, after: nil, before: nil, unread: nil, limit: 50)
      read do |db|
        where = [ MESSAGE ]
        binds = []
        if chat
          where << "j.chat_id = ?"
          binds << find_chat(db, chat, scope)[:rowid]
        elsif (ids = visible_ids(db, scope))
          where << "j.chat_id IN (#{marks(ids)})"
          binds.concat(ids)
        end
        if after
          where << "m.date >= ?"
          binds << apple(db, after)
        end
        if before
          where << "m.date < ?"
          binds << apple(db, before)
        end
        if from
          if from.strip.casecmp?("me")
            where << "m.is_from_me = 1"
          else
            senders = sender_ids(db, from)
            return empty_page if senders.empty?

            where << "m.is_from_me = 0 AND m.handle_id IN (#{marks(senders)})"
            binds.concat(senders)
          end
        end
        unless unread.nil?
          where << (unread ? "m.is_from_me = 0 AND m.is_read = 0" : "NOT (m.is_from_me = 0 AND m.is_read = 0)")
        end
        sql = "SELECT #{COLUMNS} #{FROM} WHERE #{where.join(' AND ')} ORDER BY m.date DESC, m.ROWID DESC LIMIT ? OFFSET ?"

        if q
          search(db, sql, binds, q, limit)
        else
          rows = select(db, sql, binds + [ limit + 1, 0 ])
          page(db, rows.first(limit), truncated: rows.size > limit, searched_back_to: nil)
        end
      end
    end

    def message(id, scope: nil)
      read do |db|
        row = select(db, "SELECT #{COLUMNS} #{FROM} WHERE m.guid = ? LIMIT 1", [ id ]).first
        raise NotFound.new("message", "no message #{id.inspect}") if row.nil? || !chat_visible?(db, row.chat_rowid, scope)

        shape(db, [ row ]).first
      end
    end

    # What is new after `since` (a seq), oldest first. Without `since`, the
    # place to start: the newest seq now. The cursor moves past everything
    # looked at, including what the scope or the filter left out.
    def changes(scope: nil, since: nil, from_me: nil, limit: 100)
      read do |db|
        top = db.get_first_value("SELECT IFNULL(MAX(ROWID), 0) FROM message").to_i
        next { "cursor" => top.to_s, "messages" => [], "more" => false } if since.nil?

        where = [ MESSAGE, "m.ROWID > ?", "m.ROWID <= ?" ]
        binds = [ since, top ]
        if (ids = visible_ids(db, scope))
          where << "j.chat_id IN (#{marks(ids)})"
          binds.concat(ids)
        end
        where << "m.is_from_me = #{from_me ? 1 : 0}" unless from_me.nil?
        rows = select(db, "SELECT #{COLUMNS} #{FROM} WHERE #{where.join(' AND ')} ORDER BY m.ROWID ASC LIMIT ?", binds + [ limit + 1 ])
        more = rows.size > limit
        rows = rows.first(limit)
        { "cursor" => (more ? rows.last.rowid : [ top, since ].max).to_s, "messages" => shape(db, rows), "more" => more }
      end
    end

    def status(scope: nil)
      read do |db|
        where = [ MESSAGE ]
        binds = []
        if (ids = visible_ids(db, scope))
          where << "j.chat_id IN (#{marks(ids)})"
          binds.concat(ids)
        end
        count, latest_date, latest_seq = db.get_first_row(
          "SELECT COUNT(*), MAX(m.date), MAX(m.ROWID) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE #{where.join(' AND ')}", binds
        )
        chats = all_chats(db).count { |chat| visible?(chat, scope) }
        { "path" => path, "messages" => count.to_i, "chats" => chats, "latest_at" => iso(latest_date), "latest_seq" => latest_seq&.to_s }
      end
    end

    # --- what sending needs ---

    # Where a send goes: an existing chat, by id or by the person in it, or a
    # new conversation with someone Messages has not talked to.
    # -> { "chat" => guid, "rowid" => n } or { "participant" => handle }
    def destination(scope: nil, chat: nil, to: nil)
      read do |db|
        next(find_chat(db, chat, scope).then { |found| { "chat" => found[:guid], "rowid" => found[:rowid] } }) if chat

        key = Handles.key(to)
        raise NotFound.new("handle", "#{to.inspect} is not a phone number or address") if key.nil?

        # all_chats is newest first, so the first match is the most recent.
        found = all_chats(db).find { |candidate| !candidate[:group] && Handles.key(one_handle(candidate)) == key }
        next { "chat" => found[:guid], "rowid" => found[:rowid] } if found

        { "participant" => to }
      end
    end

    def latest_seq
      read { |db| db.get_first_value("SELECT IFNULL(MAX(ROWID), 0) FROM message").to_i }
    end

    # The message from this account that a send made: after `seq`, in the
    # chat (or a one-to-one chat with the person), with the same words.
    def sent(after:, text:, chat_rowid: nil, to: nil)
      read do |db|
        rows = select(db, "SELECT #{COLUMNS} #{FROM} WHERE #{MESSAGE} AND m.is_from_me = 1 AND m.ROWID > ? ORDER BY m.ROWID ASC LIMIT 50", [ after ])
        wanted = clean(text)
        chats = chat_rowid ? {} : all_chats(db).to_h { |chat| [ chat[:rowid], chat ] }
        row = rows.find do |candidate|
          here = chat_rowid ? candidate.chat_rowid == chat_rowid : Handles.same?(one_handle(chats[candidate.chat_rowid]), to)
          here && message_text(candidate) == wanted
        end
        row && shape(db, [ row ]).first
      end
    end

    private

    def read
      db = SQLite3::Database.new(path, readonly: true)
      db.busy_timeout = 2000
      yield db
    rescue SQLite3::CantOpenException, SQLite3::PermissionException, SQLite3::AuthorizationException => e
      raise Unavailable, "herald cannot read the Messages database at #{path} (#{e.message}): give Herald.app Full Disk Access " \
                         "under System Settings → Privacy & Security, then restart herald"
    rescue SQLite3::BusyException
      raise Unavailable, "the Messages database stayed busy; try again"
    rescue SQLite3::Exception => e
      raise Unavailable, "the Messages database could not be read: #{e.class.name.split('::').last}: #{e.message}"
    ensure
      db&.close
    end

    def select(db, sql, binds)
      db.execute(sql, binds).map { |values| Row.new(*values) }
    end

    def empty_page
      { "messages" => [], "count" => 0, "truncated" => false, "searched_back_to" => nil }
    end

    # The text has to be decoded to be searched, so a search reads newest
    # first in batches until it has enough or has read SEARCH_LIMIT.
    def search(db, sql, binds, q, limit)
      words = q.downcase.split
      found = []
      scanned = 0
      last = nil
      exhausted = false
      while found.size <= limit && scanned < SEARCH_LIMIT
        batch = select(db, sql, binds + [ BATCH, scanned ])
        batch.each do |row|
          text = message_text(row)
          found << row if text && words.all? { |word| text.downcase.include?(word) }
        end
        scanned += batch.size
        last = batch.last || last
        if batch.size < BATCH
          exhausted = true
          break
        end
      end
      stopped = !exhausted && found.size <= limit
      page(db, found.first(limit), truncated: found.size > limit, searched_back_to: stopped && last ? iso(last.date) : nil)
    end

    def page(db, rows, truncated:, searched_back_to:)
      messages = shape(db, rows)
      { "messages" => messages, "count" => messages.size, "truncated" => truncated, "searched_back_to" => searched_back_to }
    end

    def shape(db, rows)
      return [] if rows.empty?

      attachments = attachments_for(db, rows)
      reactions = reactions_for(db, rows)
      rows.map do |row|
        from_me = row.from_me == 1
        {
          "id" => row.guid, "seq" => row.rowid, "chat_id" => row.chat_guid, "from_me" => from_me,
          "sender" => from_me ? nil : { "handle" => row.handle, "name" => @contacts.name(row.handle) },
          "text" => message_text(row), "sent_at" => iso(row.date), "read_at" => iso(row.date_read),
          "delivered_at" => from_me ? iso(row.date_delivered) : nil,
          "read" => from_me ? row.date_read.to_i.positive? : row.is_read == 1,
          "service" => row.service, "reply_to" => blank(row.thread),
          "edited" => row.date_edited.to_i.positive?, "unsent" => row.date_retracted.to_i.positive?,
          "attachments" => attachments.fetch(row.rowid, []), "reactions" => reactions.fetch(row.guid, [])
        }
      end
    end

    def message_text(row)
      return nil if row.date_retracted.to_i.positive?

      clean(row.text || Typedstream.text(row.body))
    end

    def clean(text)
      return nil if text.nil?

      cleaned = text.delete(OBJECT_REPLACEMENT).strip
      cleaned.empty? ? nil : cleaned
    end

    def attachments_for(db, rows)
      ids = rows.select { |row| row.has_attachments == 1 }.map(&:rowid)
      return {} if ids.empty?

      sql = <<~SQL
        SELECT j.message_id, a.transfer_name, a.filename, a.mime_type, a.uti, a.total_bytes
          FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id
         WHERE j.message_id IN (#{marks(ids)}) AND IFNULL(a.hide_attachment, 0) = 0
         ORDER BY j.message_id, a.ROWID
      SQL
      db.execute(sql, ids).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(message, name, file, mime, uti, size), found|
        found[message] << { "name" => blank(name) || (file && File.basename(file)), "type" => blank(mime) || blank(uti), "size" => size }
      end
    end

    # Tapbacks are found by the chats on the page and the time of its oldest
    # message (a tapback comes after what it answers), then folded onto
    # their messages in order, so one taken back is gone.
    def reactions_for(db, rows)
      chats = rows.map(&:chat_rowid).uniq
      sql = <<~SQL
        SELECT m.associated_message_guid, m.associated_message_type, m.associated_message_emoji, m.is_from_me, h.id
          FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN handle h ON h.ROWID = m.handle_id
         WHERE j.chat_id IN (#{marks(chats)}) AND m.date >= ? AND m.associated_message_type BETWEEN 2000 AND 3999
         ORDER BY m.date, m.ROWID
      SQL
      wanted = rows.to_set(&:guid)
      found = Hash.new { |hash, key| hash[key] = [] }
      db.execute(sql, chats + [ rows.map(&:date).compact.min || 0 ]).each do |target, type, emoji, from_me, handle|
        guid = target.to_s.sub(%r{\A(?:p:\d+/|bp:)}, "")
        next unless wanted.include?(guid)

        kind = REACTIONS[type % 1000] or next
        mine = from_me == 1
        who = mine ? :me : Handles.key(handle)
        # One of each kind per person: a new one replaces it, and taking one
        # back (3000+) removes it. Emoji tapbacks differ by their emoji.
        list = found[guid]
        list.reject! { |entry| entry[:who] == who && entry[:kind] == kind && (kind != "emoji" || type >= 3000 || entry[:emoji] == emoji) }
        list << { who: who, kind: kind, emoji: blank(emoji), mine: mine, handle: handle } if type < 3000
      end
      found.transform_values do |list|
        list.map do |entry|
          { "reaction" => entry[:kind], "emoji" => entry[:emoji], "from_me" => entry[:mine],
            "from" => entry[:mine] ? nil : { "handle" => entry[:handle], "name" => @contacts.name(entry[:handle]) } }
        end
      end
    end

    def unread_counts(db, rowids)
      return {} if rowids.empty?

      sql = "SELECT j.chat_id, COUNT(*) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID " \
            "WHERE #{MESSAGE} AND m.is_from_me = 0 AND m.is_read = 0 AND j.chat_id IN (#{marks(rowids)}) GROUP BY j.chat_id"
      db.execute(sql, rowids).to_h
    end

    # Every chat that has a message, newest first, with its handles.
    def all_chats(db)
      handles = Hash.new { |hash, key| hash[key] = [] }
      db.execute("SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id ORDER BY j.chat_id, h.ROWID")
        .each { |chat, handle| handles[chat] << handle unless handles[chat].include?(handle) }
      sql = <<~SQL
        SELECT c.ROWID, c.guid, c.chat_identifier, c.service_name, c.style, c.display_name, j.last_date
          FROM chat c JOIN (SELECT chat_id, MAX(message_date) AS last_date FROM chat_message_join GROUP BY chat_id) j ON j.chat_id = c.ROWID
         ORDER BY j.last_date DESC, c.ROWID DESC
      SQL
      db.execute(sql).map do |rowid, guid, identifier, service, style, display_name, last_date|
        list = handles.fetch(rowid, [])
        { rowid: rowid, guid: guid, identifier: identifier, service: service, group: style == 43 || list.size > 1,
          display_name: blank(display_name), last_date: last_date.to_i, handles: list }
      end
    end

    # A chat by id, or by identifier (the number, address, or group name
    # Messages files it under), newest first when several share one.
    def find_chat(db, id, scope)
      found = all_chats(db).select { |chat| chat[:guid] == id || chat[:identifier] == id }
      found = found.find { |chat| visible?(chat, scope) }
      raise NotFound.new("chat", "no chat #{id.inspect}") unless found

      found
    end

    def one_handle(chat)
      return nil if chat.nil? || chat[:group]

      chat[:handles].first || chat[:identifier]
    end

    def visible?(chat, scope)
      return true if scope.nil?
      return true if scope.chats.include?(chat[:guid]) || scope.chats.include?(chat[:identifier])

      handle = one_handle(chat)
      !handle.nil? && scope.handle?(handle)
    end

    def chat_visible?(db, rowid, scope)
      scope.nil? || visible_ids(db, scope).include?(rowid)
    end

    # nil when the key sees everything; otherwise the chat rowids it sees.
    def visible_ids(db, scope)
      return nil if scope.nil?

      all_chats(db).select { |chat| visible?(chat, scope) }.map { |chat| chat[:rowid] }
    end

    def chat_shape(chat)
      participants = chat[:handles].map { |handle| { "handle" => handle, "name" => @contacts.name(handle) } }
      if participants.empty? && !chat[:group] && chat[:identifier]
        participants = [ { "handle" => chat[:identifier], "name" => @contacts.name(chat[:identifier]) } ]
      end
      name = chat[:display_name] || participants.map { |p| p["name"] || p["handle"] }.join(", ")
      { "id" => chat[:guid], "identifier" => chat[:identifier], "service" => chat[:service],
        "group" => chat[:group], "name" => blank(name) || chat[:identifier], "display_name" => chat[:display_name],
        "participants" => participants, "last_message_at" => iso(chat[:last_date]) }
    end

    # Handles a sender filter could mean: in part of the handle, the digits
    # of a number however it was typed, or a name in Contacts.
    def sender_ids(db, from)
      text = from.strip.downcase
      digits = text.match?(/[a-z@]/) ? "" : text.gsub(/\D/, "")
      named = @contacts.handles_named(text).to_set
      db.execute("SELECT ROWID, id FROM handle").filter_map do |rowid, handle|
        handle = handle.to_s
        match = handle.downcase.include?(text) || (digits.length >= 3 && handle.gsub(/\D/, "").include?(digits)) ||
                named.include?(Handles.key(handle))
        rowid if match
      end
    end

    # Since High Sierra, dates are nanoseconds since 2001; before, seconds.
    # Any date in nanoseconds is far above what seconds could reach, so a
    # value says which it is, and a filter is written the way the newest
    # message in the database is.
    NANOS = 1_000_000_000_000

    def apple(db, time)
      seconds = time.to_r - APPLE_EPOCH
      nanos = db.get_first_value("SELECT IFNULL(MAX(date), 0) FROM message").to_i > NANOS
      (nanos ? seconds * 1_000_000_000 : seconds).to_i
    end

    def iso(value)
      value = value.to_i
      return nil unless value.positive?

      Time.at(APPLE_EPOCH + (value > NANOS ? value / 1_000_000_000 : value)).utc.iso8601
    end

    def marks(list)
      Array.new(list.size, "?").join(", ")
    end

    def blank(value)
      value.nil? || value.to_s.strip.empty? ? nil : value
    end
  end
end
