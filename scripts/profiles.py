#!/usr/bin/env python3
"""Game profile catalog: validates profile issues and builds site/catalog.json.

Rules mirror GameProfile.problems in Sources/NokcanduCore/Profiles.swift. Profiles are settings only:
no files, paths or code. Votes are the issue's 👍/👎 reactions; comments are the discussion.

Usage (in GitHub Actions, with GITHUB_TOKEN and GITHUB_REPOSITORY set):
  profiles.py validate <issue-number>   label the issue profile-valid / profile-invalid (+ comment)
  profiles.py build <out-dir>           write catalog.json for all open, valid profile issues
"""
import json, os, re, sys, urllib.request, urllib.error

REPO = os.environ.get("GITHUB_REPOSITORY", "seastwood/Nokcandu")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
API = f"https://api.github.com/repos/{REPO}"
SOURCES = {"steam", "battlenet", "installer", "disc", "folder"}
GRAPHICS = {"dx9", "dx11", "d3dmetal", "ddraw", "wined3d"}
RATINGS = {"works", "playable", "broken"}
FIXES = {"cinematic"}
BANNED = {"PATH", "HOME", "SHELL", "TMPDIR", "WINEPREFIX", "WINESERVER", "WINELOADER", "WINEARCH", "VK_DRIVER_FILES"}
BANNED_PARTS = ["DYLD_", "LD_", "NOKCANDU", "WINEDLLPATH", "PRELOAD", "ICD", "VK_LAYER", "VK_ADD_"]
APP = "{app}"
MARK = "<!-- nokcandu-profile-check -->"


def api(path, method="GET", data=None):
    url = path if path.startswith("http") else API + path
    req = urllib.request.Request(url, method=method, data=None if data is None else json.dumps(data).encode())
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "nokcandu-profiles")
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req) as r:
        body = r.read()
        return json.loads(body) if body else None


def env_name_allowed(k):
    return bool(re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", k)) and k not in BANNED and not any(p in k for p in BANNED_PARTS)


def env_value_allowed(v):
    if not isinstance(v, str) or len(v) > 300 or "\n" in v or ".." in v:
        return False
    if "/" in v:
        return v.startswith(APP + "/") and "{" not in v[len(APP):]
    return True


def parse(body):
    m = re.search(r"```(?:json)?\s*\n([\s\S]*?)\n```", body or "")
    text = m.group(1) if m else (body or "")
    return json.loads(text)


def normalize(p):
    """Returns (clean_profile, problems). The clean profile has exactly the shape Nokcandu decodes."""
    probs = []
    if not isinstance(p, dict):
        return None, ["profile must be a JSON object"]
    out = {"schema": 1}
    if p.get("schema", 1) != 1:
        probs.append("unknown schema")
    title = p.get("title")
    if not isinstance(title, str) or not (1 <= len(title.strip()) <= 100):
        probs.append("title must be 1–100 characters")
    out["title"] = title
    src = p.get("source")
    if src not in SOURCES:
        probs.append("source must be one of " + ", ".join(sorted(SOURCES)))
    out["source"] = src
    rating = p.get("rating")
    if rating not in RATINGS:
        probs.append("rating must be works, playable or broken")
    out["rating"] = rating
    m = p.get("match") if isinstance(p.get("match"), dict) else {}
    match = {}
    if isinstance(m.get("steamAppID"), int) and m["steamAppID"] > 0:
        match["steamAppID"] = m["steamAppID"]
    if isinstance(m.get("battleNetUID"), str):
        if re.fullmatch(r"[a-z0-9_.\-]{1,30}", m["battleNetUID"]): match["battleNetUID"] = m["battleNetUID"]
        else: probs.append("battleNetUID looks wrong")
    if isinstance(m.get("exeName"), str):
        if re.fullmatch(r'[^/\\:*?"<>|]{1,80}\.exe', m["exeName"], re.I): match["exeName"] = m["exeName"]
        else: probs.append("exeName must be a plain .exe file name")
    if not match:
        probs.append("match needs steamAppID, battleNetUID or exeName")
    out["match"] = match
    for key in ("install", "notes"):
        v = p.get(key)
        if v is None: continue
        if not isinstance(v, str) or len(v) > 4000: probs.append(f"{key} must be text up to 4000 characters")
        else: out[key] = v
    g = p.get("graphics")
    if g is not None:
        if g in GRAPHICS: out["graphics"] = g
        else: probs.append("unknown graphics mode")
    a = p.get("arguments")
    if a is not None:
        if isinstance(a, str) and len(a) <= 300 and "\n" not in a: out["arguments"] = a
        else: probs.append("launch options must be one line, ≤300 characters")
    env = p.get("environment")
    if env is not None:
        if not isinstance(env, dict) or len(env) > 30:
            probs.append("environment must be up to 30 settings")
        else:
            for k, v in env.items():
                if not env_name_allowed(k): probs.append(f"setting {k} isn't allowed in shared profiles")
                if not env_value_allowed(v):
                    probs.append(f"setting {k} has a value that isn't allowed (one line; file paths only inside the game's app, as {{app}}/…)")
            if env: out["environment"] = env
    r = p.get("rawMouse")
    if r is not None:
        if isinstance(r, (int, float)) and not isinstance(r, bool) and (r == 0 or 0.1 <= r <= 10): out["rawMouse"] = float(r)
        else: probs.append("rawMouse must be 0 (off) or 0.1–10")
    perf = p.get("performance")
    if perf is not None:
        if not isinstance(perf, dict): probs.append("performance must be an object")
        else:
            fc, vs, fl = perf.get("fpsCounter", False), perf.get("vsync", False), perf.get("fpsLimit", 0)
            if not (isinstance(fc, bool) and isinstance(vs, bool) and isinstance(fl, int) and not isinstance(fl, bool) and (fl == 0 or 10 <= fl <= 360)):
                probs.append("performance values are invalid (fpsLimit 0 or 10–360)")
            else: out["performance"] = {"fpsCounter": fc, "vsync": vs, "fpsLimit": fl}
    fx = p.get("fixes")
    if fx is not None:
        if isinstance(fx, list) and all(f in FIXES for f in fx): out["fixes"] = fx
        else: probs.append("unknown fix")
    prog = p.get("program")
    if prog is not None:
        if isinstance(prog, str) and re.fullmatch(r'[A-Za-z]:\\[^\n:*?"<>|]{1,250}\.exe', prog, re.I) and ".." not in prog: out["program"] = prog
        else: probs.append("program must be a Windows path to an .exe")
    ha = p.get("hostArguments")
    if ha is not None:
        if isinstance(ha, str) and len(ha) <= 300 and "\n" not in ha: out["hostArguments"] = ha
        else: probs.append("Battle.net launch options must be one line, ≤300 characters")
    dr = p.get("drives")
    if dr is not None:
        if isinstance(dr, list) and all(isinstance(d, str) and re.fullmatch(r"[D-Yd-y]", d) for d in dr): out["drives"] = [d.upper() for d in dr]
        else: probs.append("drives must be letters D–Y")
    if p.get("disc") is not None:
        if isinstance(p["disc"], bool): out["disc"] = p["disc"]
        else: probs.append("disc must be true or false")
    t = p.get("tested")
    if isinstance(t, dict):
        out["tested"] = {k: str(v)[:120] for k, v in t.items() if k in ("mac", "macOS", "engine", "nokcandu") and isinstance(v, str)}
    return out, probs


def validate(number):
    issue = api(f"/issues/{number}")
    labels = {l["name"] for l in issue.get("labels", [])}
    if "profile" not in labels or issue.get("pull_request"):
        return
    try:
        _, probs = normalize(parse(issue.get("body")))
    except Exception as e:  # not JSON
        probs = [f"the Profile box must contain the JSON Nokcandu created ({e.__class__.__name__})"]
    ok = not probs
    want, drop = ("profile-valid", "profile-invalid") if ok else ("profile-invalid", "profile-valid")
    if drop in labels:
        try: api(f"/issues/{number}/labels/{drop}", "DELETE")
        except urllib.error.HTTPError: pass
    if want not in labels:
        api(f"/issues/{number}/labels", "POST", {"labels": [want]})
    # One status comment, updated in place.
    text = (MARK + "\n" + ("✅ **Published.** This profile is in the Game Profiles catalog (updates hourly). "
            "Vote 👍 if it works for you, 👎 if it doesn't, and comment with tips." if ok else
            "⚠️ **Not published yet** — please edit the issue to fix:\n" + "\n".join(f"- {x}" for x in probs)))
    mine = [c for c in api(f"/issues/{number}/comments?per_page=100") if MARK in (c.get("body") or "")]
    if mine:
        if mine[0]["body"] != text: api(f"/issues/comments/{mine[0]['id']}", "PATCH", {"body": text})
    else:
        api(f"/issues/{number}/comments", "POST", {"body": text})
    print(f"#{number}: {'valid' if ok else 'invalid: ' + '; '.join(probs)}")


def build(out_dir):
    entries, page = [], 1
    while True:
        batch = api(f"/issues?labels=profile&state=open&per_page=100&page={page}")
        if not batch: break
        for i in batch:
            if i.get("pull_request"): continue
            names = {l["name"] for l in i.get("labels", [])}
            if TOKEN and not names & {"profile-valid", "profile-invalid"}:
                try: validate(i["number"])   # e.g. a check that was skipped while another run was queued
                except Exception as e: print(f"#{i['number']}: couldn't label ({e})")
            try:
                prof, probs = normalize(parse(i.get("body")))
            except Exception:
                continue
            if probs: continue
            rx = i.get("reactions") or {}
            entries.append({"number": i["number"], "url": i["html_url"], "author": i["user"]["login"],
                            "up": rx.get("+1", 0), "down": rx.get("-1", 0), "comments": i.get("comments", 0),
                            "updated": i["updated_at"], "created": i["created_at"], "profile": prof})
        page += 1
    entries.sort(key=lambda e: (-(e["up"] - e["down"]), e["profile"]["title"].lower()))
    os.makedirs(out_dir, exist_ok=True)
    import datetime
    with open(os.path.join(out_dir, "catalog.json"), "w") as f:
        json.dump({"generated": datetime.datetime.now(datetime.timezone.utc).isoformat(), "profiles": entries}, f, indent=1, ensure_ascii=False)
    print(f"catalog: {len(entries)} profiles")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "validate": validate(int(sys.argv[2]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "build": build(sys.argv[2])
    else: sys.exit(__doc__)
