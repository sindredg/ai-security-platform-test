#!/bin/bash
# Makes an API token for one of the two NetBox accounts that cannot get one
# through the API (platform ADR 0037 and 0039). Runs as root on the NetBox VM,
# through Django's shell in the running container.
#
#   seed   aisec-seed, a superuser, which makes every other account and token
#          through the API. Its token may write, is limited to the
#          orchestrator's address, and expires after an hour.
#   probe  aisec-address-probe, with no permission. Its token is read-only and
#          limited to 192.0.2.1, a documentation address that no host has. A
#          request that NetBox accepts with it took its address from a header.
#
# Neither account has a password. Each run deletes the account's tokens and
# makes one. The token goes to standard output and nowhere else, as the value
# that follows "Bearer " in a request's Authorization header. The caller pipes
# it to the orchestrator. The probe's token has to exist before the address
# setting does, so that the setting can be seen to fail.
#
# Usage: make-netbox-token.sh seed|probe
set -euo pipefail

case ${1:-} in
  seed) account=aisec-seed superuser=True write=True allowed=10.40.0.4/32 hours=1 ;;
  probe) account=aisec-address-probe superuser=False write=False allowed=192.0.2.1/32 hours=0 ;;
  *)
    echo "usage: make-netbox-token.sh seed|probe" >&2
    exit 1
    ;;
esac
if [ "$(id -u)" != 0 ]; then
  echo "make-netbox-token.sh: run as root" >&2
  exit 1
fi

# The values above are fixed words and addresses, so they can go into the code
# as they are. The code prints the token on a line of its own, after whatever
# Django prints, and only that line leaves this script.
code="
from datetime import timedelta

from django.utils import timezone
from netaddr import IPNetwork
from users.models import Token, User

user = User.objects.filter(username='$account').first()
if user is None:
    make = User.objects.create_superuser if $superuser else User.objects.create_user
    user = make('$account')
if user.is_superuser != $superuser or user.has_usable_password():
    raise SystemExit('$account exists with other settings')
Token.objects.filter(user=user).delete()
token = Token(
    user=user,
    write_enabled=$write,
    allowed_ips=[IPNetwork('$allowed')],
    expires=timezone.now() + timedelta(hours=$hours) if $hours else None,
    description='made on the NetBox VM by make-netbox-token.sh',
)
token.full_clean()
token.save()
print(f'token=nbt_{token.key}.{token.token}')
"
out=$(podman exec netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c "$code")
token=$(sed -n 's/^token=//p' <<< "$out")
if ! [[ $token =~ ^nbt_[A-Za-z0-9]{12}\.[A-Za-z0-9]{40}$ ]]; then
  echo "make-netbox-token.sh: no token in the shell's output" >&2
  exit 1
fi
printf '%s\n' "$token"
