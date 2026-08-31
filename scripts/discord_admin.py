"""Minimal Discord REST helper for the AI server.

Reads the bot token from the ACL-locked bridge config; the token never leaves
this machine. stdlib only -- no dependency on the conda env.

  python discord_admin.py guild-info
  python discord_admin.py create-channel --name qwen-foo [--topic "..."]
  python discord_admin.py post --channel <id> --file msg.txt
"""
import argparse, json, os, sys, time, urllib.request, urllib.error

TOKEN_ENV = r"C:\AI-Server\state\discord-bridge\token.env"
API = "https://discord.com/api/v10"


def cfg():
    out = {}
    with open(TOKEN_ENV, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def call(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bot " + token)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "AIServerBot (https://local, 1.0)")
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            if e.code == 429:
                try:
                    wait = float(json.loads(raw).get("retry_after", 2))
                except Exception:
                    wait = 2.0
                time.sleep(wait + 0.3)
                continue
            print("HTTP %s %s -> %s" % (e.code, path, raw), file=sys.stderr)
            raise
    raise SystemExit("rate limited repeatedly on " + path)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("guild-info")
    c = sub.add_parser("create-channel")
    c.add_argument("--name", required=True)
    c.add_argument("--topic", default="")
    p = sub.add_parser("post")
    p.add_argument("--channel", required=True)
    p.add_argument("--file", required=True)
    a = ap.parse_args()

    conf = cfg()
    token = conf["DISCORD_BOT_TOKEN"]
    guild = conf["ALLOWED_GUILD_IDS"].split(",")[0].strip()

    if a.cmd == "guild-info":
        me = call("GET", "/users/@me", token)
        g = call("GET", "/guilds/%s" % guild, token)
        chans = call("GET", "/guilds/%s/channels" % guild, token)
        print("bot: %s#%s (%s)" % (me.get("username"), me.get("discriminator"), me.get("id")))
        print("guild: %s (%s)" % (g.get("name"), guild))
        print("channels:")
        for ch in sorted(chans, key=lambda x: (x.get("type"), x.get("position", 0))):
            print("  [%s] %-28s type=%s" % (ch["id"], ch.get("name"), ch.get("type")))

    elif a.cmd == "create-channel":
        ch = call("POST", "/guilds/%s/channels" % guild, token,
                  {"name": a.name, "type": 0, "topic": a.topic[:1024]})
        print(json.dumps({"id": ch["id"], "name": ch["name"]}))

    elif a.cmd == "post":
        with open(a.file, "r", encoding="utf-8") as f:
            text = f.read()
        # Discord caps a message at 2000 chars. Split on blank lines, never mid-line.
        chunks, cur = [], ""
        for para in text.split("\n\n"):
            block = (para + "\n\n")
            while len(block) > 1900:      # a single oversized paragraph
                if cur:
                    chunks.append(cur); cur = ""
                cut = block.rfind("\n", 0, 1900)
                cut = cut if cut > 0 else 1900
                chunks.append(block[:cut])
                block = block[cut:]
            if len(cur) + len(block) > 1900:
                chunks.append(cur); cur = block
            else:
                cur += block
        if cur.strip():
            chunks.append(cur)
        for i, ch in enumerate(chunks):
            call("POST", "/channels/%s/messages" % a.channel, token, {"content": ch.rstrip()})
            time.sleep(0.6)
        print("posted %d message(s) to %s" % (len(chunks), a.channel))


if __name__ == "__main__":
    main()
