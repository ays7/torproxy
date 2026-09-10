#!/usr/bin/env bash
#===============================================================================
#          FILE: torproxy.sh
#   DESCRIPTION: Entrypoint and supervisor for torproxy docker container
#        AUTHOR: ays7 (https://github.com/ays7/torproxy)
#                Original by David Personette (dperson@gmail.com)
#===============================================================================

set -o nounset
set -o pipefail

TOR_CONF="${TOR_CONF:-/etc/tor/torrc}"
PRIVOXY_CONF="${PRIVOXY_CONF:-/etc/privoxy/config}"

### bandwidth: set the BW available for relaying
bandwidth() {
    local kbs="${1:-10}"
    sed -i '/^RelayBandwidth/d' "$TOR_CONF"
    echo "RelayBandwidthRate $kbs KB" >> "$TOR_CONF"
    echo "RelayBandwidthBurst $(( kbs * 2 )) KB" >> "$TOR_CONF"
}

### exitnode: Allow exit traffic
exitnode() {
    sed -i '/^ExitPolicy/d' "$TOR_CONF"
}

### exitnode_country: Only allow traffic to exit in a specified country
exitnode_country() {
    local country="$1"
    sed -i '/^StrictNodes/d; /^ExitNodes/d' "$TOR_CONF"
    echo "StrictNodes 1" >> "$TOR_CONF"
    echo "ExitNodes {$country}" >> "$TOR_CONF"
}

### hidden_service: configure a hidden service port mapping
hidden_service() {
    local port="$1"
    local host="$2"
    local hs_dir="/var/lib/tor/hidden_service"
    if ! grep -q "^HiddenServiceDir" "$TOR_CONF"; then
        echo "HiddenServiceDir $hs_dir" >> "$TOR_CONF"
    fi
    sed -i "/^HiddenServicePort $port /d" "$TOR_CONF"
    echo "HiddenServicePort $port $host" >> "$TOR_CONF"
}

### parse_service_spec: safely parse "port;target:port" without eval
parse_service_spec() {
    local spec="$1"
    local port target
    IFS=';' read -r port target <<< "$spec"
    if [[ -n "$port" && -n "$target" ]]; then
        hidden_service "$port" "$target"
    else
        echo "WARNING: Invalid hidden service spec '$spec'. Expected format: '<port>;<host:port>'" >&2
    fi
}

### parse_service_list: handle comma-separated hidden service specifications
parse_service_list() {
    local list="$1"
    local item
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] && parse_service_spec "$item"
    done
}

### newnym: request new Tor circuit via control port
newnym() {
    local file="/etc/tor/run/control.authcookie"
    if [[ ! -r "$file" ]]; then
        echo "ERROR: Tor control auth cookie not readable: $file" >&2
        return 1
    fi
    local hex
    hex="$(hexdump -ve '1/1 "%.2x"' "$file" 2>/dev/null)"
    if [[ -z "$hex" ]]; then
        echo "ERROR: Failed to read control auth cookie as hex" >&2
        return 1
    fi
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$hex" | nc 127.0.0.1 9051
    if pgrep -x tor >/dev/null 2>&1; then
        exit 0
    fi
}

### password: configure HashedControlPassword and open control port to all interfaces
password() {
    local passwd="$1"
    local hash
    hash="$(tor --hash-password "$passwd" 2>/dev/null | tail -n 1)"
    if [[ -n "$hash" ]]; then
        sed -i '/^HashedControlPassword/d' "$TOR_CONF"
        sed -i 's/^ControlPort .*/ControlPort 0.0.0.0:9051/' "$TOR_CONF"
        echo "HashedControlPassword $hash" >> "$TOR_CONF"
    else
        echo "ERROR: Failed to generate Tor hashed password" >&2
        return 1
    fi
}

### usage: Display help
usage() {
    local rc="${1:-0}"
    cat <<EOF >&2
Usage: ${0##*/} [options] [command]

Options:
    -h                      Show this help message
    -b <kbs>                Configure tor relay bandwidth in KB/s (burst = 2x)
    -e                      Allow exit node traffic (clears ExitPolicy reject)
    -l <country>            Configure tor exit country code (e.g., US, DE)
    -n                      Request new circuit (SIGNAL NEWNYM) and exit
    -p <password>           Set HashedControlPassword and bind ControlPort to 0.0.0.0:9051
    -s "<port>;<host:port>" Configure tor hidden service (supports comma-separated list)

Environment Variables:
    BW                      Bandwidth limit in KB/s
    EXITNODE                Set to 1 or true to allow exit node traffic
    LOCATION                Country code for exit node (e.g. US, DE)
    PASSWORD                Tor control port password
    SERVICE                 Hidden service mapping (e.g. "80;web:80")
    TORUSER                 Run Tor as named user (default: tor)
    USERID                  UID for the tor user
    GROUPID                 GID for the tor user
    TOR_<Option>            Directly inject or override any torrc option (e.g. TOR_NewCircuitPeriod=400)

EOF
    exit "$rc"
}

### apply_dynamic_env: inject TOR_* variables safely into torrc
apply_dynamic_env() {
    while IFS='=' read -r env_var env_val; do
        case "$env_var" in
            TOR_CONF)
                continue
                ;;
            TOR_*)
                local name="${env_var#TOR_}"
                [[ -z "$name" || -z "$env_val" ]] && continue

                if grep -q "^[[:space:]]*$name\b" "$TOR_CONF"; then
                    awk -v n="$name" -v v="$env_val" '
                        $1 == n { print n " " v; next }
                        { print }
                    ' "$TOR_CONF" > "$TOR_CONF.tmp" && mv "$TOR_CONF.tmp" "$TOR_CONF"
                else
                    echo "$name $env_val" >> "$TOR_CONF"
                fi
                ;;
        esac
    done < <(printenv)
}

main() {
    # Parse command line flags
    while getopts ":hb:el:np:s:" opt; do
        case "$opt" in
            h) usage 0 ;;
            b) bandwidth "$OPTARG" ;;
            e) exitnode ;;
            l) exitnode_country "$OPTARG" ;;
            n) newnym ;;
            p) password "$OPTARG" ;;
            s) parse_service_list "$OPTARG" ;;
            \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
            :)  echo "Option -$OPTARG requires an argument." >&2; usage 2 ;;
        esac
    done
    shift $(( OPTIND - 1 ))

    # Apply environment variable configurations
    [[ -n "${BW:-""}" ]] && bandwidth "$BW"
    [[ -n "${EXITNODE:-""}" && "${EXITNODE}" =~ ^(1|true|TRUE|yes|YES)$ ]] && exitnode
    [[ -n "${LOCATION:-""}" ]] && exitnode_country "$LOCATION"
    [[ -n "${PASSWORD:-""}" ]] && password "$PASSWORD"
    [[ -n "${SERVICE:-""}" ]] && parse_service_list "$SERVICE"

    # User & Group ID mapping
    if [[ "${USERID:-""}" =~ ^[0-9]+$ ]]; then
        usermod -u "$USERID" -o tor 2>/dev/null || :
    fi
    if [[ "${GROUPID:-""}" =~ ^[0-9]+$ ]]; then
        groupmod -g "$GROUPID" -o tor 2>/dev/null || :
    fi

    # Support custom TORUSER
    if [[ -n "${TORUSER:-""}" ]]; then
        sed -i "s/^User .*/User $TORUSER/" "$TOR_CONF"
        chown -Rh "$TORUSER" /var/lib/tor /etc/tor /var/log/tor 2>/dev/null || :
    fi

    # Inject dynamic TOR_* variables
    apply_dynamic_env

    # If a custom command was provided, execute it instead of starting services
    if [[ $# -ge 1 ]]; then
        if command -v "$1" >/dev/null 2>&1; then
            exec "$@"
        else
            echo "ERROR: Command not found: $1" >&2
            exit 13
        fi
    fi

    # Ensure directories and permissions
    mkdir -p /etc/tor/run /var/lib/tor /var/log/tor /var/log/privoxy 2>/dev/null || :
    chown -Rh tor:tor /etc/tor /var/lib/tor /var/log/tor 2>/dev/null | grep -iv 'Read-only' || :
    chmod 0700 /var/lib/tor 2>/dev/null || :
    chmod 0750 /etc/tor/run 2>/dev/null || :

    # Background listener to display onion hostname when created
    if grep -q "^HiddenServiceDir" "$TOR_CONF"; then
        hs_dir="$(grep "^HiddenServiceDir" "$TOR_CONF" | awk '{print $2}' | head -n 1)"
        if [[ -n "$hs_dir" ]]; then
            (
                for _ in $(seq 1 60); do
                    if [[ -s "$hs_dir/hostname" ]]; then
                        echo "=================================================="
                        echo "Tor Hidden Service Hostname: $(cat "$hs_dir/hostname")"
                        echo "=================================================="
                        break
                    fi
                    sleep 1
                done
            ) &
        fi
    fi

    # Dual-process supervision
    local privoxy_pid=""
    local tor_pid=""

    shutdown() {
        echo "Signal received, shutting down services..."
        [[ -n "$tor_pid" ]] && kill -TERM "$tor_pid" 2>/dev/null
        [[ -n "$privoxy_pid" ]] && kill -TERM "$privoxy_pid" 2>/dev/null
        wait 2>/dev/null || :
        exit 0
    }

    trap shutdown SIGTERM SIGINT SIGHUP

    echo "Starting Privoxy..."
    /usr/sbin/privoxy --no-daemon --user privoxy "$PRIVOXY_CONF" &
    privoxy_pid=$!

    echo "Starting Tor..."
    /usr/bin/tor -f "$TOR_CONF" &
    tor_pid=$!

    # Wait for either process to terminate
    wait -n "$tor_pid" "$privoxy_pid"
    local exit_code=$?
    echo "A service stopped unexpectedly (exit code: $exit_code). Terminating..."
    shutdown
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi