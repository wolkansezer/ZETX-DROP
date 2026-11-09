"""Shows TestFlight state for ZETX DROP and sets up internal testing:
an internal group with access to all builds, containing the team's own users."""
import json, os, re, sys, time, urllib.error, urllib.request

import jwt

BUNDLE = "om.zetx.drop"
kid = re.sub(r"\s", "", os.environ["ASC_KEY_ID"])
iss = re.sub(r"\s", "", os.environ["ASC_ISSUER_ID"])
raw = os.environ["ASC_KEY_P8"]
body = re.sub(r"[^A-Za-z0-9+/=]", "", re.sub(r"-----(BEGIN|END)[^-]*-----", "", raw))
pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END PRIVATE KEY-----\n"
tok = jwt.encode({"iss": iss, "iat": int(time.time()), "exp": int(time.time()) + 1100, "aud": "appstoreconnect-v1"},
                 pem, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})


def call(method, path, data=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read()
            return r.status, json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        txt = e.read()
        return e.code, json.loads(txt) if txt else {}


def errs(b):
    return "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in b.get("errors", []))


c, apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE}&limit=1")
if c != 200 or not apps.get("data"):
    sys.exit(f"::error::Uygulama bulunamadı ({c}) {errs(apps)}")
app = apps["data"][0]["id"]
print("Uygulama:", apps["data"][0]["attributes"]["name"])

c, builds = call("GET", f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=5&fields[builds]=version,processingState,uploadedDate,expired,usesNonExemptEncryption")
for b in builds.get("data", []):
    a = b["attributes"]
    print(f"Yapı {a['version']}: durum={a['processingState']} yüklendi={a['uploadedDate']} süresi_doldu={a['expired']} şifreleme={a.get('usesNonExemptEncryption')}")
if not builds.get("data"):
    print("::warning::Henüz işlenmiş yapı görünmüyor (yükleme yeni ise birkaç dakika bekleyin).")

# Builds need an export-compliance answer before testers can install them.
for b in builds.get("data", []):
    if b["attributes"].get("usesNonExemptEncryption") is None and b["attributes"]["processingState"] == "VALID":
        c, r = call("PATCH", f"/v1/builds/{b['id']}", {"data": {"type": "builds", "id": b["id"], "attributes": {"usesNonExemptEncryption": False}}})
        print(f"Şifreleme beyanı ({b['attributes']['version']}): {c} {errs(r)}")

c, groups = call("GET", f"/v1/apps/{app}/betaGroups?limit=50")
internal = [g for g in groups.get("data", []) if g["attributes"].get("isInternalGroup")]
print("Test grupları:", [(g["attributes"]["name"], "dahili" if g["attributes"].get("isInternalGroup") else "harici") for g in groups.get("data", [])] or "YOK")
if internal:
    group = internal[0]
else:
    c, r = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups",
              "attributes": {"name": "ZETX Ekip", "isInternalGroup": True, "hasAccessToAllBuilds": True},
              "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
    if c not in (200, 201):
        sys.exit(f"::error::Dahili test grubu oluşturulamadı ({c}) {errs(r)}")
    group = r["data"]
    print("Dahili test grubu oluşturuldu: ZETX Ekip")
gid = group["id"]
if not group["attributes"].get("hasAccessToAllBuilds"):
    for b in builds.get("data", []):
        c, r = call("POST", f"/v1/betaGroups/{gid}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
        print(f"Yapı gruba eklendi ({b['attributes']['version']}): {c} {errs(r)}")

c, members = call("GET", f"/v1/betaGroups/{gid}/betaTesters?limit=200")
have = {m["attributes"].get("email", "").lower() for m in members.get("data", [])}
c, users = call("GET", "/v1/users?limit=50&fields[users]=username,firstName,lastName,roles")
for u in users.get("data", []):
    a = u["attributes"]
    email = (a.get("username") or "").lower()
    masked = re.sub(r"(^.).*(@.*$)", r"\1***\2", email)
    if not email or email in have:
        print(f"Test kullanıcısı zaten grupta: {masked}")
        continue
    c, r = call("POST", "/v1/betaTesters", {"data": {"type": "betaTesters",
              "attributes": {"email": email, "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
              "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
    print(f"Test kullanıcısı eklendi: {masked} → {c} {errs(r)}")
print("Bitti. iPhone'da TestFlight uygulamasını App Store Connect'teki Apple hesabınla açın.")
