"""Seeds NetBox with exercise 1's synthetic inventory and accounts.

Platform ADR 0037. Runs as root on the orchestrator, with the seeding token,
which may write and is limited to the orchestrator's address. Python's standard
library only, so the orchestrator needs nothing installed for it.

It makes each object in the seed that NetBox lacks, found by the key the seed
names. An object that exists and differs from the seed stops the run. This
script changes and deletes no inventory, account, or permission.

Each run deletes the tokens of each account in the seed's token list and makes
one new token for it. NetBox shows a token's value once, in the answer that
makes it, so the value goes straight to TOKEN_DIR/<account>, root's, mode 600.
Nobody keeps an account's password, so it has no other way in.

Usage: seed.py SEED TOKEN_DIR
"""

import json
import os
import re
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = "https://10.50.0.4:8443"
CERT = "/etc/aisec/netbox/tls.crt"
SEED_TOKEN = "/etc/aisec/netbox/seed-token"  # noqa: S105 - the file's path
TOKEN_FORM = re.compile(r"nbt_[A-Za-z0-9]{12}\.[A-Za-z0-9]{40}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses redirects, which would carry the token to another address."""

    def redirect_request(self, *args):
        return None


class NetBox:
    def __init__(self, token):
        context = ssl.create_default_context(cafile=CERT)
        # The orchestrator's proxy settings name Squid on the edge. NetBox is
        # reached directly, so the proxy handler has no proxies.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=context),
            NoRedirect(),
        )
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        # The URL is NetBox's fixed address and a path from this script.
        request = urllib.request.Request(  # noqa: S310
            URL + path, data=data, method=method, headers=self.headers
        )
        try:
            with self.opener.open(request, timeout=30) as answer:
                text = answer.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:500]
            sys.exit(f"{method} {path}: {error.code} {detail}")
        return json.loads(text) if text else None

    def find(self, path, **query):
        query["limit"] = 1000
        found = self.call("GET", f"{path}?{urllib.parse.urlencode(query)}")
        if found["next"]:
            sys.exit(f"GET {path}: more than one page")
        return found["results"]


def matches(want, have, field):
    """Whether NetBox's value for a field is the seed's."""
    if field == "constraints":
        return want == have
    if field == "users":
        return sorted(want) == sorted(user["username"] for user in have)
    if isinstance(want, dict):
        # A related object, named by attributes. NetBox answers with its brief
        # form, which holds them.
        return isinstance(have, dict) and all(have.get(k) == v for k, v in want.items())
    if isinstance(have, dict):
        # A choice field: NetBox answers {"value": ..., "label": ...}.
        return want == have.get("value")
    if isinstance(want, list):
        return sorted(want) == sorted(have)
    return want == have


def body_for(netbox, path, item):
    """The seed's item as NetBox takes it on creation."""
    body = dict(item)
    if path == "/api/users/users/":
        # NetBox requires a password. Nobody keeps this one. Its default rules
        # ask for a digit, an uppercase and a lowercase letter, which hex
        # alone does not always give, so a fixed suffix does.
        body["password"] = secrets.token_hex(32) + "Aa1"
    if path == "/api/users/permissions/":
        # Users go by ID here, not by attributes.
        body["users"] = [
            the_one(netbox.find("/api/users/users/", username=name), name)["id"]
            for name in item["users"]
        ]
    return body


def the_one(found, what):
    if len(found) != 1:
        sys.exit(f"{what}: {len(found)} found, 1 expected")
    return found[0]


def seed_objects(netbox, groups):
    for group in groups:
        path, key = group["path"], group["key"]
        for item in group["items"]:
            name = item[key]
            found = netbox.find(path, **{key: name})
            if not found:
                netbox.call("POST", path, body_for(netbox, path, item))
                print(f"made  {path} {name}")
                continue
            have = the_one(found, f"{path} {name}")
            differ = [f for f, v in item.items() if not matches(v, have.get(f), f)]
            if differ:
                sys.exit(f"{path} {name} differs from the seed in {', '.join(differ)}")
            print(f"have  {path} {name}")


def make_tokens(netbox, specs, token_dir):
    for spec in specs:
        account = spec["user"]
        user = the_one(netbox.find("/api/users/users/", username=account), account)
        for old in netbox.find("/api/users/tokens/", user_id=user["id"]):
            netbox.call("DELETE", f"/api/users/tokens/{old['id']}/")
        made = netbox.call(
            "POST",
            "/api/users/tokens/",
            {
                "user": user["id"],
                "write_enabled": spec["write_enabled"],
                "allowed_ips": spec["allowed_ips"],
                "description": "made by seed.py",
            },
        )
        token = f"nbt_{made['key']}.{made['token']}"
        if not TOKEN_FORM.fullmatch(token):
            sys.exit(f"{account}: the answer held no token")
        path = os.path.join(token_dir, account)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write(token + "\n")
        os.chmod(path, 0o600)
        print(f"made  token for {account}, in {path}")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: seed.py SEED TOKEN_DIR")
    if os.geteuid() != 0:
        sys.exit("seed.py: run as root")
    with open(sys.argv[1]) as file:
        seed = json.load(file)
    with open(SEED_TOKEN) as file:
        netbox = NetBox(file.read().strip())
    seed_objects(netbox, seed["objects"])
    make_tokens(netbox, seed["tokens"], sys.argv[2])


if __name__ == "__main__":
    main()
