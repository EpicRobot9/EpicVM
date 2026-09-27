from dashboard.direct_stream_auth import issue_grant, verify_grant
from scripts.host_stream_gateway import Gateway
import json
from threading import Thread
from urllib import error, parse, request


def test_grant_is_bound_to_route_and_expires():
    key = b"a" * 32
    route = "seat-" + "f" * 24
    path = f"/EpicVM/{route}/stream.html?hostId=1"
    token = issue_grant(key, route=route, user="portal:alice", path=path, now=100)
    payload = verify_grant(key, token, now=130)
    assert payload["route"] == route and payload["path"] == path
    for bad in (token[:-1] + "x",):
        try:
            verify_grant(key, bad, now=130)
        except ValueError:
            pass
        else:
            assert False, "tampered grant was accepted"
    try:
        verify_grant(key, token, now=161)
    except ValueError:
        pass
    else:
        assert False, "expired grant was accepted"


def test_grant_rejects_cross_resource_path():
    try:
        issue_grant(b"a" * 32, route="vm-astra", user="portal:alice",
                    path="/EpicVM/vm-other/", now=100)
    except ValueError:
        pass
    else:
        assert False, "cross-resource path was accepted"


def test_gateway_accepts_caddy_auth_subrequest_with_stream_query(tmp_path):
    route = "seat-" + "f" * 24
    key = b"a" * 32
    key_path = tmp_path / "key"
    routes_path = tmp_path / "routes.json"
    key_path.write_bytes(key)
    routes_path.write_text(json.dumps({route: {"enabled": True, "moonlightUser": route}}))
    gateway = Gateway(("127.0.0.1", 0), key_path=key_path,
                      routes_path=routes_path, nonces_path=tmp_path / "nonces.sqlite3")
    worker = Thread(target=gateway.serve_forever, daemon=True)
    worker.start()
    base = f"http://127.0.0.1:{gateway.server_port}"
    path = f"/EpicVM/{route}/stream.html?hostId=123&appId=456"
    grant = issue_grant(key, route=route, user="portal:alice", path=path)

    class NoRedirect(request.HTTPRedirectHandler):
        def redirect_request(self, *_args):
            return None

    try:
        body = parse.urlencode({"grant": grant}).encode()
        try:
            request.build_opener(NoRedirect).open(request.Request(base + "/redeem", data=body))
        except error.HTTPError as response:
            assert response.code == 303
            cookie = response.headers["Set-Cookie"].split(";", 1)[0]
        with request.urlopen(request.Request(base + "/authorize?hostId=123&appId=456",
                                             headers={"Cookie": cookie,
                                                      "X-Forwarded-Uri": path})) as response:
            assert response.status == 200
            assert response.headers["X-EpicVM-User"] == route
        with request.urlopen(request.Request(base + "/health")) as response:
            assert response.status == 200
    finally:
        gateway.shutdown()
        gateway.server_close()
        worker.join(timeout=2)
