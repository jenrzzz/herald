require "open3"

module Herald
  # The way out: Messages' own AppleScript `send`, one osascript per message.
  # The text and the recipient ride in as arguments (argv), never as part of
  # the script, so nothing a caller sends is ever read as code.
  #
  # Sends are serialized: Messages handles Apple Events one at a time, and a
  # queue here means two sends cannot race to the same chat out of order.
  class Sender
    SCRIPT = <<~APPLESCRIPT.freeze
      on run argv
        set theText to item 1 of argv
        set theKind to item 2 of argv
        set theTarget to item 3 of argv
        tell application "Messages"
          if theKind is "chat" then
            send theText to chat id theTarget
          else
            set theAccount to first account whose service type is iMessage
            send theText to participant theTarget of theAccount
          end if
        end tell
        return "sent"
      end run
    APPLESCRIPT

    # Messages answered, and the answer was no.
    class Refused < StandardError; end

    # Messages could not be asked at all.
    class Unavailable < StandardError; end

    def initialize(timeout: 30, osascript: "/usr/bin/osascript")
      @timeout = timeout
      @osascript = osascript
      @lock = Mutex.new
    end

    # destination: { "chat" => guid } or { "participant" => handle }
    def send_text(text, destination)
      kind, target = destination.key?("chat") ? [ "chat", destination["chat"] ] : [ "participant", destination["participant"] ]
      out, err, status = @lock.synchronize { run(text, kind, target) }
      return true if status.success? && out.strip == "sent"

      raise explain(err.to_s.strip.empty? ? out : err)
    end

    private

    def run(*arguments)
      Open3.popen3(@osascript, "-e", SCRIPT, *arguments) do |stdin, stdout, stderr, thread|
        stdin.close
        readers = [ stdout, stderr ].map do |io|
          Thread.new do
            Thread.current.report_on_exception = false
            io.read
          rescue IOError
            ""
          end
        end
        unless thread.join(@timeout)
          begin
            Process.kill("KILL", thread.pid)
          rescue Errno::ESRCH
            nil
          end
          raise Unavailable, "Messages did not answer within #{@timeout}s (is a dialog open in the app?); the message may still go"
        end
        [ readers[0].value, readers[1].value, thread.value ]
      end
    rescue Errno::ENOENT, Errno::E2BIG => e
      raise Unavailable, "could not run osascript: #{e.message}"
    end

    def explain(err)
      text = err.to_s.strip
      if text.include?("-1743") || text.match?(/not authori[sz]ed/i)
        Unavailable.new("macOS has not allowed herald to control Messages: approve it under System Settings → Privacy & Security → Automation")
      elsif text.include?("-600") || text.match?(/isn.t running/i)
        Unavailable.new("Messages is not running and could not be started")
      elsif text.include?("-1728") || text.include?("-1719")
        Refused.new("Messages could not find whom to send to (is this Mac signed in to iMessage, and is the number or address right?): #{text[0, 200]}")
      else
        Unavailable.new("Messages could not send: #{text[0, 300]}")
      end
    end
  end
end
