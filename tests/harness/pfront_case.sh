#!/usr/bin/env bash
# Shared fail-closed validation for one pfront regression invocation.
# On success PFRONT_CASE_ERRORS is the number of errors on the requested source.
# On failure PFRONT_CASE_FAILURE explains why the compiler result is unusable.
pfront_check_case_result() {
    local output="$1" rc="$2" source="$3"
    local summary errors warnings ec wc expected_rc actual_errors actual_warnings
    PFRONT_CASE_ERRORS=0
    PFRONT_CASE_FAILURE=""

    case "$rc" in
        0|1|2) ;;
        *) PFRONT_CASE_FAILURE="compiler exited abnormally (rc=$rc)"; return 1 ;;
    esac

    summary=$(printf '%s\n' "$output" | awk '
        $1 == "errors" && $2 == ":" { errors=$3; ec++ }
        $1 == "warnings" && $2 == ":" { warnings=$3; wc++ }
        END {
            if (ec == 1 && wc == 1 && errors ~ /^[0-9]+$/ && warnings ~ /^[0-9]+$/)
                print errors, warnings
        }
    ')
    if [ -z "$summary" ]; then
        PFRONT_CASE_FAILURE="missing or malformed compiler summary"
        return 1
    fi
    read -r errors warnings <<< "$summary"
    actual_errors=$(printf '%s\n' "$output" | grep -c ' error\[' || true)
    actual_warnings=$(printf '%s\n' "$output" | grep -c ' warning\[' || true)
    if [ "$errors" -ne "$actual_errors" ] || [ "$warnings" -ne "$actual_warnings" ]; then
        PFRONT_CASE_FAILURE="summary/diagnostic count mismatch (errors=$errors/$actual_errors, warnings=$warnings/$actual_warnings)"
        return 1
    fi
    if [ "$errors" -gt 0 ]; then expected_rc=2
    elif [ "$warnings" -gt 0 ]; then expected_rc=1
    else expected_rc=0
    fi
    if [ "$rc" -ne "$expected_rc" ]; then
        PFRONT_CASE_FAILURE="inconsistent status (rc=$rc, errors=$errors, warnings=$warnings)"
        return 1
    fi
    PFRONT_CASE_ERRORS=$(printf '%s\n' "$output" | grep -F "$source:" | grep -c ' error\[' || true)
    return 0
}
