# NetBox's setting for where a client's address comes from (platform ADR 0039).
# install-netbox.sh copies this file to /etc/aisec/netbox/, and both units
# mount it into /etc/netbox/config/, where netbox-docker's configuration reads
# every .py file.
#
# NetBox's default reads X-Real-IP, then X-Forwarded-For, then the connection.
# No proxy sits in front of this NetBox, so a client writes those headers
# itself, and with them the address that a token's allowed IPs are checked
# against. granian.py in this directory closes the same hole one layer down.
HTTP_CLIENT_IP_HEADERS = ("REMOTE_ADDR",)
