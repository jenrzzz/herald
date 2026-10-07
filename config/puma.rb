# One process, a few threads: reads are quick SQLite queries, and sends
# queue behind one another on their way into Messages anyway.
#
# HERALD_BIND is a comma list of addresses. The default is this Mac only;
# add the tailnet address (never 0.0.0.0) to let hob and other machines in.
port = ENV.fetch("HERALD_PORT", "8379")
ENV.fetch("HERALD_BIND", "127.0.0.1").split(",").map(&:strip).reject(&:empty?).each do |address|
  bind "tcp://#{address}:#{port}"
end
threads 1, 4
workers 0
environment ENV.fetch("RACK_ENV", "production")
