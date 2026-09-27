"""Check live gateway grant redemption without exposing the grant or cookie."""

from pathlib import Path
import json
import sys
from urllib import request, parse, error
if len(sys.argv) > 3 and sys.argv[3].startswith('https://'):
    import truststore
    truststore.inject_into_ssl()

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from direct_stream_auth import issue_grant  # noqa: E402

key = Path(sys.argv[1]).read_bytes()
route = sys.argv[2]
base = sys.argv[3].rstrip('/') if len(sys.argv) > 3 else 'http://127.0.0.1:8090'
prefix = '/EpicVM/auth' if base.startswith('https://') else ''
instance_data = json.loads((Path(sys.argv[1]).parent / route / 'server' / 'data.json').read_text(encoding='utf-8'))
host_id = next(iter(instance_data['hosts']))
path = f"/EpicVM/{route}/stream.html?hostId={host_id}&appId=881448767"
ticket = issue_grant(key, route=route, user="portal:probe", path=path)
body = parse.urlencode({"grant": ticket}).encode()
class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = request.build_opener(NoRedirect)
try:
    response = opener.open(request.Request(base + prefix + "/redeem", data=body, method="POST"))
except error.HTTPError as exc:
    response = exc
assert response.status == 303, response.status
assert response.headers["Location"] == path
cookie = response.headers["Set-Cookie"].split(";", 1)[0]
auth = request.Request(base + (f'/EpicVM/{route}/' if prefix else "/authorize"),
                       headers={"Cookie": cookie, "X-Forwarded-Uri": path})
with request.urlopen(auth) as accepted:
    assert accepted.status == 200
    if not prefix:
        assert accepted.headers["X-EpicVM-User"] == route
if prefix:
    try:
        with request.urlopen(request.Request(base + path, headers={"Cookie": cookie})) as stream:
            assert stream.status == 200
    except error.HTTPError as exc:
        raise AssertionError(f"stream page returned {exc.code}: {exc.read(120)!r}") from exc
    if '--host-check' in sys.argv:
        with request.urlopen(request.Request(
                base + f'/EpicVM/{route}/api/host?host_id={host_id}',
                headers={"Cookie": cookie, "X-EpicVM-User": "untrusted-spoof"}), timeout=25) as details:
            payload = json.load(details)
            assert str(payload['host']['host_id']) == str(host_id)
            assert str(payload['host'].get('paired', '')).lower() == 'paired'
try:
    other = "seat-f894baf2ef02de084011ce99" if route == "vm-astra-testmann" else "vm-astra-testmann"
    request.urlopen(request.Request(base + (f"/EpicVM/{other}/" if prefix else "/authorize"),
                                headers={"Cookie": cookie, "X-Forwarded-Uri": f"/EpicVM/{other}/"}))
except error.HTTPError as exc:
    assert exc.code == 401
else:
    raise AssertionError("cross-resource cookie accepted")
print("gateway redeem, exact-resource auth, and cross-resource denial passed")
