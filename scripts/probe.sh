#!/bin/sh
#===============================================================================
# OONI Probe Runner Script
# Manages periodic execution of OONI network measurement tests
#
# Environment Variables:
#   informed_consent           - Must be "true" to run (required)
#   upload_results             - Upload results to OONI (default: false)
#   sleep                      - Enable sleep between tests (default: false)
#   seconds_between_tests      - Interval between tests (default: 21600)
#   websites_max_runtime       - Max runtime for website tests (default: 0)
#   websites_enabled_category_codes - Comma-separated category codes
#   args                       - Additional arguments for ooniprobe
#
# Directories (configurable):
#   CONFIG_DIR                 - Configuration directory (default: /config)
#   DATA_DIR                   - Data directory (default: /data)
#   APP_DIR                    - Application directory (default: /app)
#===============================================================================

set -eu

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------

readonly SCRIPT_NAME="ooniprobe-runner"
readonly VERSION="1.0.1"

# Directories (configurable via environment)
readonly CONFIG_DIR="${CONFIG_DIR:-/config}"
readonly DATA_DIR="${DATA_DIR:-/data}"
readonly APP_DIR="${APP_DIR:-/app}"

# Files
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly URLS_FILE="${CONFIG_DIR}/urls.txt"
readonly LAST_RUN_FILE="${DATA_DIR}/last_run"
readonly PID_FILE="${DATA_DIR}/probe.pid"
readonly PROBE_BIN="/usr/bin/ooniprobe"

# Defaults
readonly DEFAULT_INTERVAL=21600  # 6 hours
readonly DEFAULT_MAX_RUNTIME=0
readonly DEFAULT_UPLOAD=false

# State
CHILD_PID=""

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------

_log() {
    _level="$1"
    shift
    printf '[%s] [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$SCRIPT_NAME" \
        "$_level" \
        "$*"
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@" >&2; }
log_error() { _log "ERROR" "$@" >&2; }
log_debug() { [ "${DEBUG:-0}" = "1" ] && _log "DEBUG" "$@" || true; }

#-------------------------------------------------------------------------------
# Signal Handlers
#-------------------------------------------------------------------------------

cleanup() {
    log_info "Cleaning up..."
    
    # Remove PID file
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # Kill child process if running
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        log_info "Stopping child process (PID: $CHILD_PID)..."
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
}

shutdown_handler() {
    log_info "Received shutdown signal"
    cleanup
    exit 0
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------

validate_boolean() {
    _var_name="$1"
    _value="$2"
    
    case "$_value" in
        true|false) return 0 ;;
        *)
            log_error "Invalid value for $_var_name: '$_value' (expected: true/false)"
            return 1
            ;;
    esac
}

validate_integer() {
    _var_name="$1"
    _value="$2"
    
    case "$_value" in
        ''|*[!0-9]*)
            log_error "Invalid value for $_var_name: '$_value' (expected: integer)"
            return 1
            ;;
        *) return 0 ;;
    esac
}

validate_requirements() {
    _has_errors=0

    # Check binary
    if [ ! -f "$PROBE_BIN" ]; then
        log_error "Binary not found: $PROBE_BIN"
        _has_errors=1
    elif [ ! -x "$PROBE_BIN" ]; then
        log_error "Binary not executable: $PROBE_BIN"
        _has_errors=1
    fi

    # Check informed consent (required)
    if [ "${informed_consent:-}" != "true" ]; then
        log_error "======================================================"
        log_error "INFORMED CONSENT REQUIRED"
        log_error "======================================================"
        log_error "Set 'informed_consent=true' to confirm you understand"
        log_error "the risks of running OONI Probe."
        log_error ""
        log_error "Please read: https://ooni.org/about/risks/"
        log_error "======================================================"
        _has_errors=1
    fi

    # Validate optional parameters if set
    if [ -n "${upload_results:-}" ]; then
        validate_boolean "upload_results" "$upload_results" || _has_errors=1
    fi

    if [ -n "${sleep:-}" ]; then
        validate_boolean "sleep" "$sleep" || _has_errors=1
    fi

    if [ -n "${seconds_between_tests:-}" ]; then
        validate_integer "seconds_between_tests" "$seconds_between_tests" || _has_errors=1
    fi

    if [ -n "${websites_max_runtime:-}" ]; then
        validate_integer "websites_max_runtime" "$websites_max_runtime" || _has_errors=1
    fi

    return $_has_errors
}

#-------------------------------------------------------------------------------
# Directory Setup
#-------------------------------------------------------------------------------

setup_directories() {
    for _dir in "$CONFIG_DIR" "$DATA_DIR"; do
        if [ ! -d "$_dir" ]; then
            log_info "Creating directory: $_dir"
            mkdir -p "$_dir" || {
                log_error "Failed to create directory: $_dir"
                return 1
            }
        fi

        # Check write permission
        if [ ! -w "$_dir" ]; then
            log_error "Directory not writable: $_dir"
            return 1
        fi
    done
}

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# Convert comma-separated string to JSON array
csv_to_json_array() {
    _input="${1:-}"

    if [ -z "$_input" ] || [ "$_input" = "null" ]; then
        printf 'null'
        return
    fi

    _result=""
    _old_ifs="$IFS"
    IFS=','
    set -f  # защита от glob expansion

    for _item in $_input; do
        _item=$(printf '%s' "$_item" | tr -d '[:space:]')
        [ -z "$_item" ] && continue
        _result="${_result}\"${_item}\","
    done

    set +f
    IFS="$_old_ifs"

    _result="${_result%,}"
    printf '[%s]' "$_result"
}

generate_config() {
    _category_codes=$(csv_to_json_array "${websites_enabled_category_codes:-}")

    log_debug "Generating config with category codes: $_category_codes"

    cat > "$CONFIG_FILE" << EOCONFIG
{
  "_version": 1,
  "_informed_consent": ${informed_consent:-false},
  "sharing": {
    "upload_results": ${upload_results:-$DEFAULT_UPLOAD}
  },
  "nettests": {
    "websites_max_runtime": ${websites_max_runtime:-$DEFAULT_MAX_RUNTIME},
    "websites_enabled_category_codes": ${_category_codes}
  }
}
EOCONFIG

    log_info "Configuration saved: $CONFIG_FILE"
    log_debug "$(cat "$CONFIG_FILE")"
}

#-------------------------------------------------------------------------------
# Timing Functions
#-------------------------------------------------------------------------------

get_current_time() {
    date +%s
}

get_last_run_time() {
    if [ -f "$LAST_RUN_FILE" ] && [ -r "$LAST_RUN_FILE" ]; then
        cat "$LAST_RUN_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

save_last_run_time() {
    get_current_time > "$LAST_RUN_FILE"
    log_debug "Saved last run time: $(cat "$LAST_RUN_FILE")"
}

calculate_wait_time() {
    _interval="${seconds_between_tests:-$DEFAULT_INTERVAL}"
    _last_run=$(get_last_run_time)

    # First run
    if [ "$_last_run" -eq 0 ]; then
        echo 0
        return
    fi

    _current=$(get_current_time)
    _elapsed=$((_current - _last_run))
    
    log_info "Time since last run: ${_elapsed}s"

    if [ "$_elapsed" -lt "$_interval" ]; then
        echo $((_interval - _elapsed))
    else
        echo 0
    fi
}

format_duration() {
    _seconds="$1"
    _hours=$((_seconds / 3600))
    _minutes=$(((_seconds % 3600) / 60))
    _secs=$((_seconds % 60))

    if [ "$_hours" -gt 0 ]; then
        printf '%dh %dm %ds' "$_hours" "$_minutes" "$_secs"
    elif [ "$_minutes" -gt 0 ]; then
        printf '%dm %ds' "$_minutes" "$_secs"
    else
        printf '%ds' "$_secs"
    fi
}

#-------------------------------------------------------------------------------
# Probe Execution
#-------------------------------------------------------------------------------

run_probe() {
    _exit_status=0

    log_info "========================================"
    log_info "Starting OONI Probe"
    log_info "========================================"

    if [ -f "$URLS_FILE" ]; then
        _url_count=$(wc -l < "$URLS_FILE" | tr -d ' ')
        log_info "Mode: websites (custom list: ${_url_count} URLs)"
        
        "$PROBE_BIN" run websites \
            --input-file="$URLS_FILE" \
            --config="$CONFIG_FILE" \
            ${args:-} &
    else
        log_info "Mode: unattended (all tests)"
        
        "$PROBE_BIN" run \
            --config="$CONFIG_FILE" \
            ${args:-unattended} &
    fi

    CHILD_PID=$!
    log_debug "Probe started with PID: $CHILD_PID"
    
    # Wait for completion
    wait "$CHILD_PID" || _exit_status=$?
    CHILD_PID=""

    log_info "========================================"
    log_info "Probe finished (exit code: $_exit_status)"
    log_info "========================================"

    return $_exit_status
}

#-------------------------------------------------------------------------------
# Main Loop
#-------------------------------------------------------------------------------

main_loop() {
    _interval="${seconds_between_tests:-$DEFAULT_INTERVAL}"
    _sleep_enabled="${sleep:-false}"
    _run_count=0

    log_info "Starting main loop"
    log_info "  Interval: $(format_duration "$_interval")"
    log_info "  Sleep enabled: $_sleep_enabled"
    log_info "  Upload results: ${upload_results:-$DEFAULT_UPLOAD}"

    while true; do
        # Calculate wait time
        _wait_time=$(calculate_wait_time)

        if [ "$_wait_time" -gt 0 ]; then
            if [ "$_sleep_enabled" = "true" ]; then
                log_info "Waiting $(format_duration "$_wait_time") before next run..."
                sleep "$_wait_time"
            else
                log_info "Interval not reached and sleep disabled. Exiting."
                return 0
            fi
        fi

        # Increment run counter
        _run_count=$((_run_count + 1))
        log_info "=== Run #${_run_count} ==="

        # Execute probe
        _exit_status=0
        run_probe || _exit_status=$?

        # Save timestamp on success
        if [ "$_exit_status" -eq 0 ]; then
            save_last_run_time
        else
            log_warn "Probe failed (exit: $_exit_status), keeping previous timestamp"
        fi

        # Post-run handling
        if [ "$_sleep_enabled" = "true" ]; then
            log_info "Next run in $(format_duration "$_interval")"
            sleep "$_interval"
        else
            log_info "Single run mode. Exiting."
            return 0
        fi
    done
}

#-------------------------------------------------------------------------------
# Entry Point
#-------------------------------------------------------------------------------

main() {
    log_info "========================================"
    log_info "OONI Probe Runner v${VERSION}"
    log_info "========================================"

    # Setup signal handlers
    trap shutdown_handler INT TERM HUP QUIT
    trap cleanup EXIT

    # Write PID file
    echo $$ > "$PID_FILE"

    # Setup and validate
    setup_directories || exit 1
    
    if ! validate_requirements; then
        log_error "Validation failed. Exiting."
        exit 1
    fi

    # Generate configuration
    generate_config

    # Print probe version
    if [ -x "$PROBE_BIN" ]; then
        log_info "Probe version: $("$PROBE_BIN" version 2>/dev/null || echo 'unknown')"
    fi

    # Start main loop
    main_loop
}

# Run main function
main "$@"
