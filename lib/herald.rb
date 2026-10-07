require_relative "herald/handles"
require_relative "herald/typedstream"
require_relative "herald/contacts"
require_relative "herald/store"
require_relative "herald/sender"
require_relative "herald/keys"
require_relative "herald/audit"
require_relative "herald/idempotency"
require_relative "herald/wrapper"

# herald: an HTTP API over the Messages app on this Mac. See API.md for the
# contract and README.md for running it.
module Herald
  VERSION = "0.1.0".freeze

  module_function

  def home
    File.expand_path(ENV.fetch("HERALD_HOME", "~/.config/herald"))
  end

  def keys
    @keys ||= Keys.new(ENV.fetch("HERALD_KEYS", File.join(home, "keys.json")))
  end

  def contacts
    @contacts ||= Contacts.new(root: File.expand_path(ENV.fetch("HERALD_CONTACTS", "~/Library/Application Support/AddressBook")))
  end

  def store
    @store ||= Store.new(path: File.expand_path(ENV.fetch("HERALD_DATABASE", "~/Library/Messages/chat.db")), contacts: contacts)
  end

  def sender
    @sender ||= Sender.new(timeout: Integer(ENV.fetch("HERALD_TIMEOUT", "30")))
  end

  def audit
    @audit ||= Audit.new(ENV.fetch("HERALD_AUDIT_LOG", File.expand_path("~/Library/Logs/herald/audit.jsonl")))
  end

  # How long a send waits for its message to appear in the database.
  def send_wait
    Float(ENV.fetch("HERALD_SEND_WAIT", "10"))
  end

  def macos
    @macos ||= `sw_vers -productVersion 2>/dev/null`.strip.then { |version| version.empty? ? nil : version }
  end

  # Tests swap these for fakes.
  class << self
    attr_writer :keys, :contacts, :store, :sender, :audit
  end
end

require_relative "herald/app"
