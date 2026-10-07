require "fileutils"
require "json"
require "time"

module Herald
  # Every change anyone makes through herald, one JSON object per line: when,
  # which key, what it asked for, and what came of it. Reads are not logged.
  # What a message says is private, so only its length is written down.
  class Audit
    def initialize(path)
      @path = path
      @lock = Mutex.new
    end

    def record(key:, op:, args:, outcome:, ids: nil, error: nil)
      line = { at: Time.now.utc.iso8601, key: key, op: op, args: redact(args), outcome: outcome, ids: ids, error: error }.compact
      @lock.synchronize do
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a", 0o600) { |file| file.puts(JSON.generate(line)) }
      end
    rescue SystemCallError => e
      warn "herald: could not write the audit log at #{@path}: #{e.message}"
    end

    private

    def redact(value)
      case value
      when Hash
        value.to_h do |name, inner|
          long = %w[text].include?(name.to_s) && inner.is_a?(String)
          [ name, long ? "(#{inner.length} characters)" : redact(inner) ]
        end
      when Array then value.map { |inner| redact(inner) }
      else value
      end
    end
  end
end
