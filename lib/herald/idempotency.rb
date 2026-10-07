require "digest"

module Herald
  # An agent that times out will try again. With an Idempotency-Key header,
  # the retry gets the first answer back instead of a second message. Kept in
  # memory for a day: long enough for retries, and a restart forgetting it
  # costs at worst one duplicate.
  class Idempotency
    TTL = 24 * 60 * 60
    LIMIT = 2000

    # The same key was sent with a different request.
    class Mismatch < StandardError; end

    def initialize(clock: -> { Time.now.to_f })
      @clock = clock
      @lock = Mutex.new
      @seen = {}
    end

    # Yields to do the work the first time; afterwards returns what it
    # returned then. Only successful answers are remembered.
    def once(owner, header, fingerprint)
      return yield if header.to_s.empty?

      slot = "#{owner}\n#{header}"
      digest = Digest::SHA256.hexdigest(fingerprint)
      @lock.synchronize do
        sweep
        if (entry = @seen[slot])
          raise Mismatch, "Idempotency-Key #{header.inspect} was already used for a different request" unless entry[:digest] == digest

          return entry[:answer]
        end
        answer = yield
        @seen[slot] = { digest: digest, answer: answer, at: @clock.call }
        answer
      end
    end

    private

    def sweep
      cutoff = @clock.call - TTL
      @seen.delete_if { |_, entry| entry[:at] < cutoff }
      @seen.shift while @seen.size >= LIMIT
    end
  end
end
