# herald

*Who carries word between the house and everyone else.* An HTTP API over
the Messages app on this Mac, so agents can read the household's texts and,
when a person allows it, send one, without anyone reverse-engineering
anything.

herald reads what Messages keeps (iMessage, SMS, and RCS alike) from the
app's own database, read-only, and names the people in it from Contacts. It
sends by asking Messages to send, through the app's own AppleScript `send`,
so a message herald sends is one this Mac's account sent: it shows up in
the conversation on every device like any other.

[API.md](API.md) is the contract, written for the agents that will use it
(the server also hands it out at `GET /v1/docs`). In short:

- chats, newest first, with who is in them and what is unread
- messages: by chat, sender, words, time, unread; text decoded from
  Messages' binary form, tapbacks folded onto what they answer, attachments
  named
- a changes feed: what is new since a cursor
- send to a chat or to a person, confirmed by watching for it to appear
- keys with `read` / `send` permissions, optionally **scoped** to some
  chats or some people; an audit log of every send; `Idempotency-Key` for
  safe retries

## Running

Ruby (see `.ruby-version`) and Messages, signed in, on the same Mac, in the
same login session.

```sh
bundle install
bin/herald check                                  # can herald read Messages and Contacts?
bin/herald key add me --permissions read,send
bin/herald serve                                  # 127.0.0.1:8379
curl -H "Authorization: Bearer hrd_..." localhost:8379/v1/chats
```

herald needs two permissions from macOS, both under System Settings →
Privacy & Security:

- **Full Disk Access**, to read `~/Library/Messages/chat.db` and the
  Contacts databases. macOS never asks for this one: add the app yourself
  (Herald.app under launchd, see below; your terminal when running it by
  hand). Until then every read is a 503 that says so.
- **Automation → Messages**, to send. The first send makes macOS ask on the
  Mac's own screen; say yes. Until then every send is a 503 that says so.

To keep it running across logins, and reachable from the tailnet:

```sh
HERALD_BIND=127.0.0.1,100.90.105.100 bin/herald install   # a launchd agent, started through Herald.app
bin/herald uninstall
```

### Herald.app: permissions that last

macOS files both permissions against the code identity of whatever launchd
started. Started bare, that is `ruby`, and a ruby from a version manager is
ad-hoc signed: its identity is a hash of the binary. Rebuild or upgrade
ruby and the grants are gone, reads fail, and sends hang on a consent
prompt nobody is looking at.

So `bin/herald install` starts ruby from `~/Applications/Herald.app`, a
bundle holding one small launcher (`macos/launcher.c`) that runs ruby as
its child. The app is what macOS asks about, and it is signed with a
certificate rather than identified by hash, so the answers survive
rebuilding the launcher and changing the ruby underneath it. After a ruby
upgrade, run `bin/herald install` again: only a path in the agent's plist
changes. This is the same arrangement as
[tally](../tally/README.md#tallyapp-a-permission-that-lasts), and the same
caveats apply:

```sh
bin/herald app       # build and sign it (install does this when there is none)
```

Build it in Terminal on the Mac itself, not over ssh: macOS only lets a
process in the login session sign with a keychain of yours. The certificate
is herald's own, self-signed, kept in `signing.keychain-db` under
`HERALD_HOME` with that keychain's password beside it (mode 600).
`HERALD_SIGN_IDENTITY="Developer ID Application: ..."` signs with one of
your own identities instead. `bin/herald install --no-app` starts ruby bare.

It is a Launch*Agent* on purpose: only a process in the login session may
send Apple Events to Messages, so the Mac needs to stay logged in (the
screen can lock). Bind to loopback and the tailnet address, never
`0.0.0.0`: the tailnet is the transport security, and the keys are the
authorization.

| env | default | |
|---|---|---|
| `HERALD_BIND` | `127.0.0.1` | comma list of addresses to listen on |
| `HERALD_PORT` | `8379` | |
| `HERALD_HOME` | `~/.config/herald` | where `keys.json` lives (digests only, mode 600) |
| `HERALD_DATABASE` | `~/Library/Messages/chat.db` | the Messages database |
| `HERALD_CONTACTS` | `~/Library/Application Support/AddressBook` | where Contacts keeps its databases |
| `HERALD_AUDIT_LOG` | `~/Library/Logs/herald/audit.jsonl` | one line per send (when, key, to whom, its length, never its text, outcome) and per key change |
| `HERALD_ADMIN_TOKEN` | unset | bearer token for `/v1/keys` (below); unset means those endpoints always answer `401`. `herald install` takes it from the environment, or from `$HERALD_HOME/admin.token` |
| `HERALD_TIMEOUT` | `30` | seconds to wait for Messages to take a send before answering 503 |
| `HERALD_SEND_WAIT` | `10` | seconds to watch for a sent message to appear before answering 202 |
| `HERALD_APP` | `~/Applications/Herald.app` | where `bin/herald app` builds the bundle the agent starts from |
| `HERALD_SIGN_IDENTITY` | herald's own | a code signing identity from your keychains, instead of the self-signed one |

## Keys

```sh
bin/herald chats family                                   # find a chat's id
bin/herald key add hob --permissions read,send            # every chat
bin/herald key add hob-household --permissions read,send \
  --chat "any;+;chat8273..." --handle +15551234567        # the family group, and one person
bin/herald key list
bin/herald key revoke hob-household
```

The token prints once; herald stores a SHA-256 digest. Adding a name that
exists rotates it. Changes take effect on the running server at once.

A **scoped** key sees only its chats and the one-to-one chats with its
people; every other chat, and every message in one, does not exist as far
as it can tell, and it may send only there. The check is in every query
herald makes (`lib/herald/store.rb`), so there is no path around it. That
is what lets one Messages account serve two audiences: a full key for your
own agents, and a key confined to the family thread for anything acting on
the household's behalf.

`send` is separate from `read` because a sent message cannot be taken
back. Most keys should not have it.

To change a key's permissions or scope without rotating its token, so
whatever already uses it keeps working, use `PATCH /v1/keys/:name` instead
of `key add` (which always rotates). It takes `HERALD_ADMIN_TOKEN`, not a
key; see [API.md](API.md#keys-admin).

```sh
(umask 077; openssl rand -base64 24 > ~/.config/herald/admin.token)
HERALD_BIND=127.0.0.1,100.90.105.100 bin/herald install   # puts it in the launchd agent's environment
curl -H "Authorization: Bearer $(cat ~/.config/herald/admin.token)" http://127.0.0.1:8379/v1/keys
```

## How it works

```
agent ──HTTP──▶ Herald::App (Roda)       auth, permissions, audit, idempotency
                  │
                  ├─▶ Herald::Store        chat.db, read-only, one connection per request
                  │     └─ Typedstream      the words inside attributedBody
                  │     └─ Contacts         names, from the AddressBook databases
                  │
                  └─▶ Herald::Sender       osascript: tell application "Messages" to send
```

The database is opened read-only for each request and closed after it, so
herald never holds a lock Messages wants. Newer Messages keeps most
messages' words only in `attributedBody`, an NSAttributedString archived in
NeXT's typedstream format; herald pulls the string out of it without the
rest of Foundation. Because of that, a word search decodes as it goes and
reads at most 20,000 messages per request.

A send passes the text and the recipient to `osascript` as arguments, never
as part of the script, so nothing a caller sends is read as code. Sends are
serialized. Messages' `send` returns nothing to identify what it sent, so
herald notes the newest message before sending and watches for one from
this account, in that chat, with those words.

Not built: serving attachments, starting a group chat, sending
attachments, marking messages read, and replying in a thread. Each is a
thing Messages' scripting or database can do, and none is needed yet.

## Tests

```sh
rake test     # offline: keys, handles, the typedstream decoder, the store and the API against a fixture database
rake live     # the read side of the API against the real Messages database on this Mac; sends nothing
```

## hob

In [hob](../hob) a herald server is one *text backend*: a row with this
server's URL, a key, and a realm. See hob's `TEXTS.md`. A full key at
`personal` and a key scoped to the family thread at `household` are two
rows pointing at the same herald.
