#!/usr/bin/env bash
#===============================================================================
# Kapsis - Java Version Switcher
#
# Switches between installed Java versions using SDKMAN.
#
# Usage:
#   source switch-java.sh 17
#   source switch-java.sh 8
#===============================================================================

VERSION="${1:-17}"

if [[ -z "${SDKMAN_DIR:-}" ]]; then
    export SDKMAN_DIR="/opt/sdkman"
fi

if [[ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
    # Disable strict mode - SDKMAN references ZSH_VERSION which may be unset
    set +u 2>/dev/null || true
    source "$SDKMAN_DIR/bin/sdkman-init.sh"
    set -u 2>/dev/null || true
else
    echo "Error: SDKMAN not found at $SDKMAN_DIR"
    exit 1
fi

case "$VERSION" in
    8|1.8)
        # Try zulu first (used in full-stack/java8-legacy profiles), then tem as fallback
        sdk use java 8.0.422-zulu 2>/dev/null || sdk use java 8.0.392-tem 2>/dev/null || {
            echo "Java 8 not installed."
            exit 1
        }
        ;;
    11)
        sdk use java 11.0.21-tem 2>/dev/null || sdk use java 11.0.25-zulu 2>/dev/null || {
            echo "Java 11 not installed."
            exit 1
        }
        ;;
    17)
        # Try zulu first (used in full-stack profile), then tem as fallback
        sdk use java 17.0.14-zulu 2>/dev/null || sdk use java 17.0.9-tem 2>/dev/null || {
            echo "Java 17 not installed."
            exit 1
        }
        ;;
    21)
        sdk use java 21.0.6-zulu 2>/dev/null || sdk use java 21.0.1-tem 2>/dev/null || {
            echo "Java 21 not installed."
            exit 1
        }
        ;;
    *)
        echo "Unsupported Java version: $VERSION"
        echo "Available: 8, 11, 17, 21"
        exit 1
        ;;
esac

echo "Java version: $(java -version 2>&1 | head -1)"
echo "JAVA_HOME: $JAVA_HOME"
