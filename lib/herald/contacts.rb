require "sqlite3"

module Herald
  # Names for handles, from the Contacts databases on this Mac, read-only
  # (the same Full Disk Access that opens the Messages database opens
  # these). Messages itself keeps no names, only numbers and addresses.
  #
  # Each account Contacts syncs (iCloud, Google, On My Mac) has a database of
  # its own under Sources/; all of them are read, and the first name found
  # for a handle wins. They are read again when one changes, looked at no
  # more than once a minute. Contacts that cannot be read leave every name
  # null; nothing fails for it.
  class Contacts
    RECHECK = 60

    def initialize(root: File.expand_path("~/Library/Application Support/AddressBook"), clock: -> { Time.now.to_f })
      @root = root
      @clock = clock
      @lock = Mutex.new
      @names = nil
      @stamp = nil
      @checked_at = nil
    end

    def name(handle)
      key = Handles.key(handle)
      key && names[key]
    end

    # Every handle whose name holds `text`, in any case: how a sender is
    # found by name.
    def handles_named(text)
      wanted = text.to_s.downcase
      names.select { |_, name| name.downcase.include?(wanted) }.keys
    end

    # How many people, or nil when Contacts cannot be read at all.
    def count
      names
      @people
    end

    private

    def names
      @lock.synchronize do
        now = @clock.call
        if @names.nil? || now - @checked_at.to_f >= RECHECK
          @checked_at = now
          stamp = databases.map { |path| [ path, File.mtime(path).to_f ] }
          load(stamp.map(&:first)) if stamp != @stamp
          @stamp = stamp
        end
        @names
      end
    end

    def databases
      Dir.glob(File.join(@root, "{,Sources/*/}AddressBook-v22.abcddb")).sort
    end

    def load(paths)
      names = {}
      readable = false
      paths.each do |path|
        read(path) do |name, handle|
          key = Handles.key(handle)
          names[key] ||= name if key
        end
        readable = true
      rescue SQLite3::Exception
        next
      end
      @names = names
      @people = readable ? names.values.uniq.size : nil
    end

    def read(path)
      db = SQLite3::Database.new(path, readonly: true)
      sql = <<~SQL
        SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION, r.ZNICKNAME, p.ZFULLNUMBER, NULL
          FROM ZABCDPHONENUMBER p JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
        UNION ALL
        SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION, r.ZNICKNAME, NULL, e.ZADDRESS
          FROM ZABCDEMAILADDRESS e JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
      SQL
      db.execute(sql) do |first, last, organization, nickname, number, address|
        name = [ first, last ].compact.map(&:strip).reject(&:empty?).join(" ")
        name = (organization || nickname).to_s.strip if name.empty?
        yield name, number || address unless name.empty?
      end
    ensure
      db&.close
    end
  end
end
