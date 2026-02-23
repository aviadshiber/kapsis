#!/usr/bin/env python3
"""Store a secret in Secret Service with 99designs/keyring-compatible attributes.

99designs/keyring (used by Go CLI tools like bkt) searches for items using a
hardcoded 'profile' attribute in a named collection. This script stores secrets
in that exact format, making them discoverable by those tools.

Usage: kapsis-ss-inject COLLECTION_LABEL KEY < secret_value

Arguments:
    COLLECTION_LABEL  D-Bus Secret Service collection label (e.g., "bkt")
    KEY               Item key / profile attribute value

The secret value is read from stdin.

Requires: python3-secretstorage (apt install python3-secretstorage)

See: https://github.com/aviadshiber/kapsis/issues/170
"""
import sys

try:
    import secretstorage
except ImportError:
    print("error: python3-secretstorage not installed", file=sys.stderr)
    print("Install with: apt install python3-secretstorage", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} COLLECTION_LABEL KEY", file=sys.stderr)
        sys.exit(1)

    collection_label, key = sys.argv[1], sys.argv[2]
    secret = sys.stdin.buffer.read()

    if not secret:
        print("error: no data on stdin", file=sys.stderr)
        sys.exit(1)

    try:
        conn = secretstorage.dbus_init()

        # Find existing collection by label, or create it
        target = None
        for c in secretstorage.get_all_collections(conn):
            if c.get_label() == collection_label:
                target = c
                break

        if target is None:
            target = secretstorage.create_collection(conn, collection_label)

        if target.is_locked():
            target.unlock()

        # Store with 'profile' attribute — this is what 99designs/keyring
        # (via go-libsecret) uses for SearchItems lookups
        target.create_item(key, {"profile": key}, secret, replace=True)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
