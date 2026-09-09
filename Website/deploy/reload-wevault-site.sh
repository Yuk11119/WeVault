#!/bin/sh
set -eu
# Only act when Certbot renews this site's certificate.
if [ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/wevault.online ]; then
    /usr/sbin/nginx -t
    /bin/systemctl reload nginx
fi
