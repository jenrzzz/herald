# herald API

herald is an HTTP wrapper around the Messages app on the same Mac. It reads
the conversations Messages keeps (iMessage, SMS, and RCS alike) from the
app's own database, read-only, and sends by asking the app to send, so a
message sent through herald is one the Mac's owner sent and shows up on
every device like any other.

- Base URL: `http://<host>:8379`. JSON in, JSON out. Times are ISO 8601 UTC
  (`2026-10-06T17:00:00Z`). A time given in a query must carry its offset
  (`Z` or `-07:00`); a bare date (`2026-10-06`) is midnight on the Mac.
- Auth: `Authorization: Bearer <key>`. A key carries permissions (`read`,
  `send`) and optionally a *scope* that confines it to some chats or some
  people (see Scoped keys).
- A chat's id is Messages' own (`any;-;+15551234567`, `any;+;chat8273...`):
  stable, opaque, and full of semicolons, so escape it in a path. A
  message's id is its GUID. Every message also has a `seq`, a number that
  only grows: later messages have larger ones, which is what `/v1/changes`
  counts by.
- Unknown query parameters and body fields are refused, never ignored, so a
  typo never silently does nothing.

## Errors

```
{ "error": { "code": "not_found", "kind": "chat", "message": "no chat \"any;-;+15550000000\"" } }
```

| status | code | when |
|---|---|---|
| 400 | `bad_request` | malformed JSON, an unknown parameter or field, a bad time or number |
| 401 | `unauthorized` | missing or unknown key |
| 403 | `forbidden` | the key lacks the permission, or the chat or person is outside its scope |
| 404 | `not_found` | no such chat or message (or not visible to a scoped key); `kind` says which |
| 409 | `idempotency_mismatch` | the `Idempotency-Key` was already used for a different request |
| 422 | `invalid` | a send herald or Messages refused: no text, too long, nobody to send to |
| 503 | `messages_unavailable` | the database cannot be read (Full Disk Access), or Messages could not be asked to send (Automation, not signed in) |

## Chat

```
{
  "id": "any;-;+15551234567",
  "identifier": "+15551234567",          the phone number, address, or group's own name for itself
  "service": "iMessage",                 iMessage | SMS | RCS
  "group": false,
  "name": "Ana Ruiz",                    the group's name if it has one; else who is in it
  "display_name": null,                  the name someone gave the group, if any
  "participants": [ { "handle": "+15551234567", "name": "Ana Ruiz" } ],
  "last_message_at": "2026-10-06T16:59:12Z",
  "unread": 2                            incoming messages not yet read on this Mac
}
```

`name` on a participant comes from Contacts on this Mac when the handle is
in it, and is null otherwise. A chat's `name` is its `display_name`, or
for a chat without one the participants' names (or handles), joined.

### GET /v1/chats

`{ "chats": [...], "count": n }`, the most recently active first. Chats
with no messages are left out.

| param | meaning |
|---|---|
| `q` | words that must all appear in the chat's name, identifier, or a participant's handle or name |
| `active_after` | only chats with a message at or after this time |
| `limit` | default 50, at most 500 |

### GET /v1/chats/:id

The chat.

## Message

```
{
  "id": "6F0A3E1C-2B8D-4F7A-9C11-0D5E2A4B7C90",
  "seq": 318211,
  "chat_id": "any;-;+15551234567",
  "from_me": false,
  "sender": { "handle": "+15551234567", "name": "Ana Ruiz" },     null when from_me
  "text": "Running 10 late, save me a seat",
  "sent_at": "2026-10-06T16:59:12Z",
  "read_at": null,                 when it was read (on this account's devices, or by them for one from me)
  "delivered_at": null,            from me: when it reached them, if Messages knows
  "read": false,                   incoming: read on this Mac; from me: they have read it
  "service": "iMessage",
  "reply_to": null,                the id of the message this one answers in a thread
  "edited": false,
  "unsent": false,                 the sender took it back; text is null
  "attachments": [ { "name": "IMG_2041.HEIC", "type": "image/heic", "size": 1843221 } ],
  "reactions": [ { "reaction": "loved", "emoji": null, "from_me": true, "from": null } ]
}
```

`text` is what the message says as plain text: newer Messages keeps most
messages' text only in a binary form, which herald decodes. A message that
is only an attachment has `text` null or the single object-replacement
character Messages puts in its place, removed.

Tapbacks (loved, liked, disliked, laughed, emphasized, questioned, an
emoji, a sticker) are not messages of their own here: each is folded into
`reactions` on the message it was left on, and one taken back is gone.
Group events (someone renamed the group, joined, left) are left out.

Attachments are named, typed, and sized; their contents are not served.

### GET /v1/messages

`{ "messages": [...], "count": n, "truncated": bool, "searched_back_to": iso | null }`,
newest first.

| param | meaning |
|---|---|
| `chat` | only this chat |
| `from` | the sender's handle or Contacts name, in part; `me` for messages from this account |
| `q` | words that must all appear in the text, any case |
| `after`, `before` | sent at or after, sent before |
| `unread` | `true`: incoming messages not yet read; `false`: the rest |
| `limit` | default 50, at most 500 |

`truncated` is true when more messages matched than `limit` returned: page
back with `before` set to the last one's `sent_at`. Because the text has to
be decoded to be searched, a `q` search reads at most 20,000 messages
(after the other filters); when it stopped before running out,
`searched_back_to` is the time of the oldest one it read, and narrowing
with `chat` or `after` reaches further.

### GET /v1/messages/:id

The message.

### GET /v1/changes

What is new since the last look, oldest first. The first call, without
`since`, answers `{ "cursor": "318211", "messages": [], "more": false }`:
the place to start from. Every call after gives back the last `cursor`
and gets the messages after it, and a new cursor to keep.

| param | meaning |
|---|---|
| `since` | the cursor the last call returned |
| `from_me` | `false`: only incoming messages; `true`: only this account's; default both |
| `limit` | default 100, at most 500 |

`{ "cursor": "318240", "messages": [...], "more": bool }`. `more` is true
when there were more than `limit` and the caller should ask again now. The
cursor advances past everything looked at, including what the filter or a
key's scope left out. A tapback left on an old message is not a new
message; an edit changes a message without making a new one.

### POST /v1/messages  (send)

```
{ "chat": "any;-;+15551234567",          an existing chat, or
  "to": "+15551234567",                  a phone number or address
  "text": "On my way" }                  required, at most 20,000 characters
```

Give `chat` or `to`, not both. With `to`, herald sends in the most recently
active one-to-one chat with that person, on whatever service it uses; with
none, it starts an iMessage conversation. A new group cannot be started.

herald asks Messages to send, then watches the database for the message to
appear:

- **201** `{ "message": {...} }`: Messages has it. Look at `delivered_at`
  later to know it arrived; a message Messages could not deliver shows up
  in Messages with an error and stays undelivered.
- **202** `{ "pending": true, "chat_id": ... }`: Messages took the request
  but the message had not appeared within `HERALD_SEND_WAIT` seconds (10).
  It is usually on its way; look for it with `GET /v1/messages?chat=&from=me`
  before sending again.

Send an `Idempotency-Key` header and a retry of the same request returns
the first answer instead of sending a second message. Every send is written
to the audit log (its length, never its text).

## Scoped keys

A key may be confined to some chats (by id or identifier) and some people
(by handle):

```sh
bin/herald key add hob-household --permissions read,send --chat "any;+;chat8273..." --handle +15551234567
```

A scoped key sees only its chats, and the one-to-one chats with its
people. Every other chat, and every message in one, does not exist for it:
not in listings, not by id (`404`), not in `/v1/changes`. It may send only
to its chats and its people: a `chat` outside its scope is `404` like any
other chat it cannot see, and a `to` outside it is `403`. Phone numbers match however
they are written (`+1 (555) 123-4567`, `5551234567`); addresses match in
any case.

## Status

### GET /v1/status

```
{ "herald": "0.1.0", "macos": "26.6.2",
  "database": { "path": "~/Library/Messages/chat.db", "messages": 317977, "chats": 2755,
                "latest_at": "2026-10-06T16:59:12Z", "latest_seq": "318211" },
  "contacts": { "people": 510 },               null when Contacts cannot be read
  "key": { "name": "hob", "permissions": ["read", "send"], "scope": null },
  "now": "2026-10-06T17:00:00Z" }
```

A scoped key's counts are of what it can see. Whether Messages will let
herald send is not tested here (testing would mean sending); the first
send says.

### GET /health

`{ "ok": true, "version": "0.1.0" }`, without a key and without touching
Messages.

### GET /v1/docs

This document.
