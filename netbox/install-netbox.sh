#!/bin/bash
# Installs NetBox on the NetBox VM (platform ADR 0035, 0038, and 0039). Runs as
# root, from a copy of this directory, with the image archive the orchestrator
# fetched. PostgreSQL, Valkey, and Podman are installed already, by an update
# run.
#
# The image is checked here before anything starts it: the loaded image's ID
# has to be the one image.env pins. The archive's path to this VM does not
# matter for that.
#
# Each secret is made here, once, and kept in Podman's secret store, root's
# only. The TLS key is made here too and never leaves the VM. Only the
# certificate is copied out, for the orchestrator to pin. A second run keeps
# what exists and installs the rest again.
#
# The rehearsal copy on the lab VM is installed with the same script (platform
# ADR 0044), with three values from the environment: AISEC_NETBOX_ADDRESS, the
# address in the certificate and the allowed hosts; AISEC_NETBOX_LISTEN, the
# one address Granian listens on, where the live NetBox takes every address;
# and AISEC_NETBOX_CONF, the directory for the settings and the certificate,
# since the lab VM's /etc/aisec/netbox holds the consumer's pin of the live
# NetBox. Unset, each is the live NetBox's.
#
# Usage: install-netbox.sh ARCHIVE
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
archive=${1:?usage: install-netbox.sh ARCHIVE}
# shellcheck source=/dev/null # image.env sits beside this script
. "$here/image.env"
id=${NETBOX_IMAGE_ID#sha256:}

conf=${AISEC_NETBOX_CONF:-/etc/aisec/netbox}
media=/var/lib/aisec-netbox/media
units=/etc/containers/systemd
name=netbox.aisec.internal
address=${AISEC_NETBOX_ADDRESS:-10.50.0.4}
listen=${AISEC_NETBOX_LISTEN:-0.0.0.0}
port=8443

if [ "$(id -u)" != 0 ]; then
  echo "install-netbox.sh: run as root" >&2
  exit 1
fi
if ! [[ $id =~ ^[0-9a-f]{64}$ ]]; then
  echo "image.env: NETBOX_IMAGE_ID is not a SHA-256 image ID" >&2
  exit 1
fi
for value in "$address" "$listen"; do
  if ! [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "not an IPv4 address: $value" >&2
    exit 1
  fi
done
if ! [[ $conf =~ ^/etc/aisec/[a-z-]+$ ]]; then
  echo "AISEC_NETBOX_CONF has to be a directory under /etc/aisec: $conf" >&2
  exit 1
fi
# The page check below connects where Granian listens.
probe=$listen
[ "$listen" != 0.0.0.0 ] || probe=127.0.0.1

# 1. The image. A load of another image leaves it stored, and nothing here
# starts it: the units name the pinned ID.
if podman image exists "$id"; then
  echo "have  image $NETBOX_IMAGE_ID"
else
  podman load --quiet --input "$archive"
fi
loaded=$(podman image inspect --format '{{.Id}}' "$id" 2>/dev/null || true)
if [ "$loaded" != "$id" ]; then
  echo "the archive does not hold image $NETBOX_IMAGE_ID. Nothing is started." >&2
  exit 1
fi
echo "ok    image $NETBOX_IMAGE_ID"

# 2. The secrets. 64 hex characters each, so no quoting is needed anywhere
# and NetBox's 50-character minimum for the key and the pepper holds.
secret() {
  if podman secret exists "$1"; then
    echo "have  secret $1"
  else
    openssl rand -hex 32 | tr -d '\n' | podman secret create "$1" - > /dev/null
    echo "made  secret $1"
  fi
}
secret_value() { podman secret inspect --showsecret --format '{{.SecretData}}' "$1"; }
for s in netbox_db_password netbox_valkey_password netbox_secret_key netbox_api_token_pepper; do
  secret "$s"
done

# 3. The TLS key and its certificate: self-signed, not an authority, P-256,
# 90 days, as the tool service's. The key goes from /run, which is memory,
# into the secret store, and the copy in /run is removed.
install -d -m 755 "$conf"
if podman secret exists netbox_tls_key; then
  if [ ! -f "$conf/tls.crt" ]; then
    echo "the TLS key exists without $conf/tls.crt. Remove the secret netbox_tls_key to make both again." >&2
    exit 1
  fi
  echo "have  TLS key and certificate"
else
  tmp=$(mktemp -d -p /run)
  trap 'rm -f "$tmp/tls.key" "$tmp/tls.crt"; rmdir "$tmp"' EXIT
  (
    umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$tmp/tls.key" -out "$tmp/tls.crt" -days 90 \
      -subj "/CN=$name" \
      -addext "subjectAltName=DNS:$name,IP:$address" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=serverAuth" 2> /dev/null
  )
  podman secret create netbox_tls_key "$tmp/tls.key" > /dev/null
  install -m 644 "$tmp/tls.crt" "$conf/tls.crt"
  echo "made  TLS key and certificate"
fi

# 4. PostgreSQL: the role and its database. The password goes in on standard
# input, not in an argument that other processes can read.
runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 << SQL
\set pw '$(secret_value netbox_db_password)'
SELECT format('CREATE ROLE netbox LOGIN PASSWORD %L', :'pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'netbox') \gexec
ALTER ROLE netbox PASSWORD :'pw';
SELECT 'CREATE DATABASE netbox OWNER netbox'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'netbox') \gexec
SQL
echo "ok    PostgreSQL role and database netbox"

# 5. Valkey: a password, in a file the package's configuration includes. It
# still listens on loopback only, as the package sets it.
valkey_conf=/etc/valkey/aisec-netbox.conf
install -m 640 -o valkey -g valkey /dev/null "$valkey_conf"
printf 'requirepass %s\n' "$(secret_value netbox_valkey_password)" > "$valkey_conf"
grep -qxF "include $valkey_conf" /etc/valkey/valkey.conf ||
  printf '\ninclude %s\n' "$valkey_conf" >> /etc/valkey/valkey.conf
systemctl restart valkey-server
echo "ok    Valkey password"

# 6. The settings, the media directory, and the units with the image ID in
# them. Quadlet's dry run reads every unit before systemd does. The units
# mount client-address.py and granian.py from $conf (ADR 0039).
sed -e "s/@ADDRESS@/$address/" -e "s/@LISTEN@/$listen/" "$here/netbox.env" > "$conf/netbox.env.new"
chmod 644 "$conf/netbox.env.new"
mv "$conf/netbox.env.new" "$conf/netbox.env"
install -m 644 "$here/client-address.py" "$conf/client-address.py"
install -m 644 "$here/granian.py" "$conf/granian.py"
install -d -m 755 "${media%/*}"
install -d -m 750 -o 999 -g 0 "$media"
install -d -m 755 "$units"
for unit in netbox.container netbox-worker.container; do
  sed -e "s/@NETBOX_IMAGE_ID@/$id/" -e "s|@CONF@|$conf|g" "$here/$unit" > "$units/$unit.new"
  chmod 644 "$units/$unit.new"
  mv "$units/$unit.new" "$units/$unit"
done
/usr/libexec/podman/quadlet -dryrun > /dev/null
systemctl daemon-reload
systemctl restart netbox.service netbox-worker.service
echo "ok    units started"

# 7. NetBox answers over TLS with this certificate. The first start applies
# the migrations before Granian listens, which took more than five minutes on
# this VM's two cores. A line each minute shows it is still waiting.
code=000
for i in $(seq 1 360); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$conf/tls.crt" \
    --resolve "$name:$port:$probe" "https://$name:$port/login/" || true)
  [ "$code" = 200 ] && break
  [ $((i % 12)) = 0 ] && echo "waiting $((i / 12)) min, last: $(journalctl -u netbox -n 1 -o cat --no-pager)"
  sleep 5
done
echo "login_page=$code"
echo "running_images=$(podman inspect --format '{{.Image}}' netbox netbox-worker | tr '\n' ' ')"
openssl x509 -in "$conf/tls.crt" -noout -subject -enddate -ext subjectAltName
openssl x509 -in "$conf/tls.crt" -noout -fingerprint -sha256
[ "$code" = 200 ]
