require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module Herald
  # Who may call. A key is a name, what it may do (read, send), and
  # optionally a scope confining it to some chats and some people (enforced
  # in Store, on every query). Only a digest of the token is kept; the token
  # is shown once, when it is made.
  #
  # The file is reread when it changes, so `bin/herald key ...` takes effect
  # on a running server.
  class Keys
    PERMISSIONS = %w[read send].freeze
    SCOPE_KEYS = %w[chats handles].freeze
    PREFIX = "hrd_".freeze

    # What a scoped key may see: chats by id or identifier, and people by
    # handle (their one-to-one chats, and sending to them).
    Scope = Struct.new(:chats, :handles) do
      def handle?(handle)
        key = Handles.key(handle)
        !key.nil? && handles.any? { |mine| Handles.key(mine) == key }
      end
    end

    Key = Struct.new(:name, :permissions, :scope, :created_at, :updated_at, keyword_init: true) do
      def may?(permission)
        permissions.include?(permission.to_s)
      end

      # nil for a key that sees everything.
      def confinement
        scope && Scope.new(Array(scope["chats"]), Array(scope["handles"]))
      end

      def as_json
        { "name" => name, "permissions" => permissions, "scope" => scope }
      end

      def admin_json
        as_json.merge("created_at" => created_at, "updated_at" => updated_at)
      end
    end

    class Error < StandardError; end
    class Missing < Error; end

    attr_reader :path

    def initialize(path)
      @path = path
      @lock = Mutex.new
      @loaded_at = nil
      @rows = []
    end

    def authenticate(token)
      return nil if token.to_s.empty?

      digest = Digest::SHA256.hexdigest(token)
      row = rows.find { |candidate| secure_equal?(candidate["digest"], digest) }
      row && key(row)
    end

    def all
      rows.map { |row| key(row) }
    end

    # Makes (or, for an existing name, rotates) a key and returns the token.
    def add(name, permissions: %w[read], scope: nil)
      raise Error, "a key needs a name of letters, digits, dots, dashes or underscores" unless name.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/)

      permissions = clean_permissions(permissions)
      scope = clean_scope(scope)
      token = PREFIX + SecureRandom.urlsafe_base64(32)
      update do |list|
        list.reject! { |row| row["name"] == name }
        list << { "name" => name, "digest" => Digest::SHA256.hexdigest(token), "permissions" => permissions,
                  "scope" => scope, "created_at" => Time.now.utc.iso8601 }
      end
      token
    end

    def find(name)
      row = rows.find { |candidate| candidate["name"] == name }
      row && key(row)
    end

    # Changes a key's permissions, its scope, or both, keeping its token:
    # whatever already uses the key goes on working. A nil scope sees every
    # chat; leave a keyword out to keep what the key has. Returns the key
    # before and after.
    def change(name, permissions: :keep, scope: :keep)
      permissions = clean_permissions(permissions) unless permissions == :keep
      unless scope == :keep
        widened = !scope.nil? && clean_scope(scope).nil?
        raise Error, "a scope with no chats and no handles would see every chat; to mean that, send a null scope" if widened

        scope = clean_scope(scope)
      end
      before = after = nil
      update do |list|
        row = list.find { |candidate| candidate["name"] == name } or raise Missing, "no key named #{name}"
        before = key(row)
        row["permissions"] = permissions unless permissions == :keep
        row["scope"] = scope unless scope == :keep
        row["updated_at"] = Time.now.utc.iso8601
        after = key(row)
      end
      [ before, after ]
    end

    def revoke(name)
      removed = false
      update { |list| removed = !list.reject! { |row| row["name"] == name }.nil? }
      removed
    end

    private

    def clean_permissions(permissions)
      raise Error, "permissions is a list: #{PERMISSIONS.join(', ')}" unless permissions.is_a?(Array)

      permissions = permissions.map(&:to_s).uniq
      unknown = permissions - PERMISSIONS
      raise Error, "unknown permission #{unknown.join(', ')}; there are #{PERMISSIONS.join(', ')}" if unknown.any?
      raise Error, "a key needs at least one permission" if permissions.empty?

      permissions
    end

    def clean_scope(scope)
      return nil if scope.nil?
      raise Error, "a scope is an object of chats and handles, or null for every chat" unless scope.is_a?(Hash)

      scope = scope.transform_keys(&:to_s)
      unknown = scope.keys - SCOPE_KEYS
      raise Error, "unknown scope key #{unknown.join(', ')}" if unknown.any?

      cleaned = {}
      SCOPE_KEYS.each do |kind|
        values = scope[kind]
        raise Error, "scope #{kind} is a list of strings" unless values.nil? || (values.is_a?(Array) && values.all?(String))

        values = Array(values).map(&:strip).reject(&:empty?).uniq
        cleaned[kind] = values if values.any?
      end
      bad = Array(cleaned["handles"]).select { |handle| Handles.key(handle).nil? }
      raise Error, "#{bad.join(', ')} is not a phone number or address" if bad.any?

      cleaned.empty? ? nil : cleaned
    end

    def key(row)
      Key.new(name: row["name"], permissions: row["permissions"] || [], scope: row["scope"], created_at: row["created_at"],
              updated_at: row["updated_at"])
    end

    def rows
      @lock.synchronize do
        mtime = File.exist?(path) ? File.mtime(path) : nil
        if mtime != @loaded_at
          @rows = mtime ? JSON.parse(File.read(path)).fetch("keys", []) : []
          @loaded_at = mtime
        end
        @rows
      end
    end

    def update
      @lock.synchronize do
        list = File.exist?(path) ? JSON.parse(File.read(path)).fetch("keys", []) : []
        yield list
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, JSON.pretty_generate("keys" => list) + "\n", perm: 0o600)
        File.rename(temporary, path)
        @loaded_at = nil
      end
    end

    def secure_equal?(a, b)
      return false unless a.is_a?(String) && a.bytesize == b.bytesize

      a.bytes.zip(b.bytes).reduce(0) { |sum, (x, y)| sum | (x ^ y) }.zero?
    end
  end
end
