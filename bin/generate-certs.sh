#!/bin/bash
# sheLLaMa certificate management
# Usage: ./bin/generate-certs.sh [command] [args]
#
# Commands:
#   init                    Generate Certificate Authority
#   server <name> <sans>    Generate server cert (sans: comma-separated hostnames)
#   client <name>           Generate client cert
#   list                    List all certificates
#   revoke <name>           Revoke a certificate
#   delete <name>           Delete cert + key + req files
#   help                    Show this help
#
# Examples:
#   ./bin/generate-certs.sh init
#   ./bin/generate-certs.sh server backend-1 192.168.1.230,localhost
#   ./bin/generate-certs.sh server frontend 192.168.1.229,localhost
#   ./bin/generate-certs.sh client frontend-mtls
#   ./bin/generate-certs.sh list
#   ./bin/generate-certs.sh revoke backend-1

set -e

CERT_DIR="${SHELLAMA_CERT_DIR:-/etc/shellama/pki}"
DAYS="${SHELLAMA_CERT_DAYS:-3650}"
ORG="${SHELLAMA_CERT_ORG:-sheLLaMa}"

mkdir -p "$CERT_DIR"

cmd_init() {
    if [ -f "$CERT_DIR/ca-cert.pem" ]; then
        echo "CA already exists at $CERT_DIR/ca-cert.pem"
        echo "Delete it first to regenerate."
        exit 1
    fi
    echo "Generating Certificate Authority..."
    openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096 2>/dev/null
    openssl req -new -x509 -days "$DAYS" -key "$CERT_DIR/ca-key.pem" -out "$CERT_DIR/ca-cert.pem" \
        -subj "/O=$ORG/CN=$ORG-CA"
    chmod 600 "$CERT_DIR/ca-key.pem"
    touch "$CERT_DIR/index.txt"
    echo "1000" > "$CERT_DIR/serial"
    echo "1000" > "$CERT_DIR/crlnumber"
    echo "CA generated: $CERT_DIR/ca-cert.pem"
}

cmd_server() {
    local name="$1" sans="$2"
    [ -z "$name" ] && echo "Usage: $0 server <name> <sans>" && exit 1
    [ -z "$sans" ] && echo "Usage: $0 server <name> <host1,host2,...>" && exit 1
    [ ! -f "$CERT_DIR/ca-cert.pem" ] && echo "No CA. Run: $0 init" && exit 1
    [ -f "$CERT_DIR/$name-cert.pem" ] && echo "Certificate $name already exists" && exit 1

    echo "Generating server certificate: $name (SANs: $sans)"
    openssl genrsa -out "$CERT_DIR/$name-key.pem" 4096 2>/dev/null
    openssl req -new -key "$CERT_DIR/$name-key.pem" -out "$CERT_DIR/$name-req.pem" \
        -subj "/O=$ORG/CN=$name"

    # Build SAN extension
    local san_list=""
    IFS=',' read -ra HOSTS <<< "$sans"
    for h in "${HOSTS[@]}"; do
        h=$(echo "$h" | xargs)
        if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            san_list="${san_list:+$san_list,}IP:$h"
        else
            san_list="${san_list:+$san_list,}DNS:$h"
        fi
    done
    echo "subjectAltName = $san_list" > "$CERT_DIR/$name-ext.cnf"

    openssl x509 -req -days "$DAYS" -in "$CERT_DIR/$name-req.pem" \
        -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
        -out "$CERT_DIR/$name-cert.pem" -extfile "$CERT_DIR/$name-ext.cnf"
    chmod 600 "$CERT_DIR/$name-key.pem"
    echo "Created: $CERT_DIR/$name-cert.pem, $CERT_DIR/$name-key.pem"
}

cmd_client() {
    local name="$1"
    [ -z "$name" ] && echo "Usage: $0 client <name>" && exit 1
    [ ! -f "$CERT_DIR/ca-cert.pem" ] && echo "No CA. Run: $0 init" && exit 1
    [ -f "$CERT_DIR/$name-cert.pem" ] && echo "Certificate $name already exists" && exit 1

    echo "Generating client certificate: $name"
    openssl genrsa -out "$CERT_DIR/$name-key.pem" 4096 2>/dev/null
    openssl req -new -key "$CERT_DIR/$name-key.pem" -out "$CERT_DIR/$name-req.pem" \
        -subj "/O=$ORG/CN=$name"
    openssl x509 -req -days "$DAYS" -in "$CERT_DIR/$name-req.pem" \
        -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
        -out "$CERT_DIR/$name-cert.pem"
    chmod 600 "$CERT_DIR/$name-key.pem"
    echo "Created: $CERT_DIR/$name-cert.pem, $CERT_DIR/$name-key.pem"
}

cmd_list() {
    echo "Certificates in $CERT_DIR:"
    echo ""
    for f in "$CERT_DIR"/*-cert.pem; do
        [ -f "$f" ] || continue
        local name=$(basename "$f")
        local info=$(openssl x509 -in "$f" -noout -subject -enddate 2>/dev/null)
        local subject=$(echo "$info" | grep subject | sed 's/subject=//')
        local expires=$(echo "$info" | grep notAfter | sed 's/notAfter=//')
        printf "  %-30s %s (expires %s)\n" "$name" "$subject" "$expires"
    done
}

cmd_revoke() {
    local name="$1"
    [ -z "$name" ] && echo "Usage: $0 revoke <name>" && exit 1
    [ ! -f "$CERT_DIR/$name-cert.pem" ] && echo "Certificate $name not found" && exit 1

    cat > "$CERT_DIR/ca.conf" << EOF
[ca]
default_ca = CA_default
[CA_default]
dir = $CERT_DIR
database = \$dir/index.txt
serial = \$dir/serial
crlnumber = \$dir/crlnumber
default_crl_days = 30
default_md = sha256
EOF

    echo "Revoking $name..."
    openssl ca -config "$CERT_DIR/ca.conf" -revoke "$CERT_DIR/$name-cert.pem" \
        -keyfile "$CERT_DIR/ca-key.pem" -cert "$CERT_DIR/ca-cert.pem"
    openssl ca -config "$CERT_DIR/ca.conf" -gencrl \
        -keyfile "$CERT_DIR/ca-key.pem" -cert "$CERT_DIR/ca-cert.pem" \
        -out "$CERT_DIR/crl.pem"
    echo "Revoked: $name (CRL updated)"
}

cmd_delete() {
    local name="$1"
    [ -z "$name" ] && echo "Usage: $0 delete <name>" && exit 1
    [ "$name" = "ca" ] && echo "Cannot delete CA this way. Remove $CERT_DIR/ca-*.pem manually." && exit 1

    echo "Deleting $name..."
    for suffix in -cert.pem -key.pem -req.pem -ext.cnf; do
        [ -f "$CERT_DIR/$name$suffix" ] && rm "$CERT_DIR/$name$suffix" && echo "  removed $name$suffix"
    done
}

cmd_help() {
    head -17 "$0" | tail -16
    echo ""
    echo "PKI directory: $CERT_DIR (set SHELLAMA_CERT_DIR to change)"
}

case "${1:-help}" in
    init)    cmd_init ;;
    server)  cmd_server "$2" "$3" ;;
    client)  cmd_client "$2" ;;
    list)    cmd_list ;;
    revoke)  cmd_revoke "$2" ;;
    delete)  cmd_delete "$2" ;;
    *)       cmd_help ;;
esac
