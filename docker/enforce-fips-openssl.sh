#!/bin/bash
# Configure system OpenSSL for strict FIPS
set -euo pipefail

CNF="$(readlink -f /usr/lib/ssl/openssl.cnf)"
FIPS_MODULE_CNF="/usr/lib/ssl/fipsmodule.cnf"

if [ ! -w "$CNF" ]; then
    echo "ERROR: cannot write $CNF (run as root)." >&2
    exit 1
fi

FIPS_SO="$(find /usr/lib -type f -name 'fips.so' | sort | head -n1)"
if [ -z "$FIPS_SO" ]; then
    echo "ERROR: could not find fips.so under /usr/lib" >&2
    exit 1
fi

# Generate module integrity config for the currently installed validated module.
if [ -s "$FIPS_MODULE_CNF" ]; then
    echo "Using vendor-shipped fipsmodule.cnf at $FIPS_MODULE_CNF"
else
    echo "No fipsmodule.cnf at $FIPS_MODULE_CNF; generating one from $FIPS_SO"
    openssl fipsinstall -out "$FIPS_MODULE_CNF" -module "$FIPS_SO"
fi

# Idempotency: drop any previously-applied managed block first, so re-running (e.g. the image build
# bakes it AND build-fips.sh re-runs it) doesn't append duplicate sections / .include lines. The range
# delete matches only our own markers, so it never touches distro config.
sed -i '/^# BEGIN CURITY FIPS MANAGED$/,/^# END CURITY FIPS MANAGED$/d' "$CNF"

TMP="$(mktemp)"

# Point OpenSSL init to the Curity strict-fips section. Preserve comments.
awk 'BEGIN{replaced=0}
    /^[[:space:]]*#/ {print; next}
    /^[[:space:]]*openssl_conf[[:space:]]*=/ && replaced==0 {
        print "openssl_conf = curity_fips_init"; replaced=1; next
    }
    {print}
    END{if (replaced==0) print "openssl_conf = curity_fips_init"}' "$CNF" > "$TMP"
mv "$TMP" "$CNF"

cat >> "$CNF" <<'EOF'
# BEGIN CURITY FIPS MANAGED
.include /usr/lib/ssl/fipsmodule.cnf

[curity_fips_init]
providers = curity_provider_sect
alg_section = curity_algorithm_sect

[curity_provider_sect]
fips = fips_sect
base = curity_base_sect

[curity_base_sect]
activate = 1

[curity_algorithm_sect]
default_properties = fips = yes

# END CURITY FIPS MANAGED
EOF

# Verify strict enforcement using the patched distro config.
OPENSSL_CONF="$CNF" openssl list -providers | grep -qE '^[[:space:]]+fips$'
if OPENSSL_CONF="$CNF" openssl list -providers | grep -qE '^[[:space:]]+default$'; then
    echo "ERROR: default provider still active; strict FIPS not enforced" >&2
    exit 1
fi

printf x | OPENSSL_CONF="$CNF" openssl dgst -sha256 >/dev/null
if printf x | OPENSSL_CONF="$CNF" openssl dgst -md5 >/dev/null 2>&1; then
    echo "ERROR: MD5 still works; implicit fetch is not constrained to FIPS" >&2
    exit 1
fi

echo "OpenSSL strict FIPS configured in $CNF"
