# Replaces netbox-docker's /opt/netbox/netbox/netbox/granian.py, the module
# its launch script hands Granian as netbox.granian:application (platform ADR
# 0039). netbox.container mounts this file over it.
#
# Upstream's module wraps NetBox in Granian's proxy-header middleware and
# trusts every private range. For a client in 10.0.0.0/8, which every client
# here is, the middleware sets REMOTE_ADDR from the client's own
# X-Forwarded-For. No proxy sits in front of this NetBox, so this module hands
# Granian NetBox's application unwrapped, and REMOTE_ADDR stays the address of
# the connection.
from netbox.wsgi import application

__all__ = ["application"]
