#!/usr/bin/env bash
#===============================================================================
# Test: JSON Utilities (json-utils.sh)
#
# Unit tests for scripts/lib/json-utils.sh - the basic JSON parsing utilities.
#
# Tests verify:
#   - json_get_string extracts string values correctly
#   - json_get_number extracts numeric values correctly
#   - json_get_bool extracts boolean values correctly
#   - json_escape_string properly escapes special characters
#   - json_is_valid performs basic JSON validation
#   - Double-sourcing protection works
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

# Source the JSON utilities library under test
source "$KAPSIS_ROOT/scripts/lib/json-utils.sh"

#===============================================================================
# json_get_string() TESTS
#===============================================================================

test_json_get_string_simple() {
    log_test "json_get_string: extracts simple string value"

    local json='{"name": "hello world"}'
    local result
    result=$(json_get_string "$json" "name")

    assert_equals "hello world" "$result" "Should extract simple string value"
}

test_json_get_string_with_spaces() {
    log_test "json_get_string: handles spaces in value"

    local json='{"message": "hello   world  with   spaces"}'
    local result
    result=$(json_get_string "$json" "message")

    assert_equals "hello   world  with   spaces" "$result" "Should preserve spaces in value"
}

test_json_get_string_empty() {
    log_test "json_get_string: handles empty string value"

    local json='{"empty": ""}'
    local result
    result=$(json_get_string "$json" "empty")

    assert_equals "" "$result" "Should return empty for empty string value"
}

test_json_get_string_missing_key() {
    log_test "json_get_string: returns empty for missing key"

    local json='{"name": "value"}'
    local result
    result=$(json_get_string "$json" "nonexistent")

    assert_equals "" "$result" "Should return empty for missing key"
}

test_json_get_string_with_numbers() {
    log_test "json_get_string: extracts string containing numbers"

    local json='{"version": "1.2.3"}'
    local result
    result=$(json_get_string "$json" "version")

    assert_equals "1.2.3" "$result" "Should extract string with numbers"
}

test_json_get_string_compact() {
    log_test "json_get_string: handles compact JSON (no spaces)"

    local json='{"key":"value"}'
    local result
    result=$(json_get_string "$json" "key")

    assert_equals "value" "$result" "Should handle compact JSON without spaces"
}

test_json_get_string_with_colons() {
    log_test "json_get_string: handles colons in value"

    local json='{"url": "https://example.com:8080/path"}'
    local result
    result=$(json_get_string "$json" "url")

    assert_equals "https://example.com:8080/path" "$result" "Should handle colons in value"
}

test_json_get_string_first_of_multiple() {
    log_test "json_get_string: returns first match for duplicate keys"

    local json='{"key": "first", "key": "second"}'
    local result
    result=$(json_get_string "$json" "key")

    assert_equals "first" "$result" "Should return first match for duplicate keys"
}

test_json_get_string_multiline() {
    log_test "json_get_string: handles multiline JSON"

    local json='{
        "name": "test value",
        "other": "data"
    }'
    local result
    result=$(json_get_string "$json" "name")

    assert_equals "test value" "$result" "Should handle multiline JSON"
}

#===============================================================================
# json_get_number() TESTS
#===============================================================================

test_json_get_number_integer() {
    log_test "json_get_number: extracts integer value"

    local json='{"count": 42}'
    local result
    result=$(json_get_number "$json" "count")

    assert_equals "42" "$result" "Should extract integer value"
}

test_json_get_number_zero() {
    log_test "json_get_number: extracts zero"

    local json='{"value": 0}'
    local result
    result=$(json_get_number "$json" "value")

    assert_equals "0" "$result" "Should extract zero"
}

test_json_get_number_negative() {
    log_test "json_get_number: extracts negative number"

    local json='{"offset": -10}'
    local result
    result=$(json_get_number "$json" "offset")

    assert_equals "-10" "$result" "Should extract negative number"
}

test_json_get_number_null() {
    log_test "json_get_number: extracts null value"

    local json='{"nothing": null}'
    local result
    result=$(json_get_number "$json" "nothing")

    assert_equals "null" "$result" "Should extract null as string 'null'"
}

test_json_get_number_missing_key() {
    log_test "json_get_number: returns empty for missing key"

    local json='{"count": 42}'
    local result
    result=$(json_get_number "$json" "nonexistent")

    assert_equals "" "$result" "Should return empty for missing key"
}

test_json_get_number_compact() {
    log_test "json_get_number: handles compact JSON"

    local json='{"num":123}'
    local result
    result=$(json_get_number "$json" "num")

    assert_equals "123" "$result" "Should handle compact JSON"
}

test_json_get_number_large() {
    log_test "json_get_number: handles large numbers"

    local json='{"big": 9999999999}'
    local result
    result=$(json_get_number "$json" "big")

    assert_equals "9999999999" "$result" "Should handle large numbers"
}

#===============================================================================
# json_get_bool() TESTS
#===============================================================================

test_json_get_bool_true() {
    log_test "json_get_bool: extracts true value"

    local json='{"enabled": true}'
    local result
    result=$(json_get_bool "$json" "enabled")

    assert_equals "true" "$result" "Should extract true value"
}

test_json_get_bool_false() {
    log_test "json_get_bool: extracts false value"

    local json='{"disabled": false}'
    local result
    result=$(json_get_bool "$json" "disabled")

    assert_equals "false" "$result" "Should extract false value"
}

test_json_get_bool_missing_key() {
    log_test "json_get_bool: returns empty for missing key"

    local json='{"enabled": true}'
    local result
    result=$(json_get_bool "$json" "nonexistent")

    assert_equals "" "$result" "Should return empty for missing key"
}

test_json_get_bool_compact() {
    log_test "json_get_bool: handles compact JSON"

    local json='{"flag":true}'
    local result
    result=$(json_get_bool "$json" "flag")

    assert_equals "true" "$result" "Should handle compact JSON"
}

test_json_get_bool_multiline() {
    log_test "json_get_bool: handles multiline JSON"

    local json='{
        "first": false,
        "second": true
    }'
    local result
    result=$(json_get_bool "$json" "second")

    assert_equals "true" "$result" "Should handle multiline JSON"
}

#===============================================================================
# json_escape_string() TESTS
#===============================================================================

test_json_escape_string_quotes() {
    log_test "json_escape_string: escapes double quotes"

    local result
    result=$(json_escape_string 'say "hello"')

    assert_equals 'say \"hello\"' "$result" "Should escape double quotes"
}

test_json_escape_string_backslash() {
    log_test "json_escape_string: escapes backslashes"

    local result
    result=$(json_escape_string 'path\to\file')

    assert_equals 'path\\to\\file' "$result" "Should escape backslashes"
}

test_json_escape_string_newline() {
    log_test "json_escape_string: escapes newlines"

    local input=$'line1\nline2'
    local result
    result=$(json_escape_string "$input")

    assert_equals 'line1\nline2' "$result" "Should escape newlines"
}

test_json_escape_string_tab() {
    log_test "json_escape_string: escapes tabs"

    local input=$'col1\tcol2'
    local result
    result=$(json_escape_string "$input")

    assert_equals 'col1\tcol2' "$result" "Should escape tabs"
}

test_json_escape_string_carriage_return() {
    log_test "json_escape_string: escapes carriage returns"

    local input=$'line1\rline2'
    local result
    result=$(json_escape_string "$input")

    assert_equals 'line1\rline2' "$result" "Should escape carriage returns"
}

test_json_escape_string_combined() {
    log_test "json_escape_string: handles multiple escape sequences"

    local input=$'He said "hello\nworld" with a\\backslash'
    local result
    result=$(json_escape_string "$input")

    assert_equals 'He said \"hello\nworld\" with a\\backslash' "$result" \
        "Should handle multiple escape sequences"
}

test_json_escape_string_empty() {
    log_test "json_escape_string: handles empty string"

    local result
    result=$(json_escape_string "")

    assert_equals "" "$result" "Should return empty for empty input"
}

test_json_escape_string_no_escaping_needed() {
    log_test "json_escape_string: returns unchanged when no escaping needed"

    local result
    result=$(json_escape_string "simple text")

    assert_equals "simple text" "$result" "Should return unchanged when no escaping needed"
}

#===============================================================================
# json_is_valid() TESTS
#===============================================================================

test_json_is_valid_object() {
    log_test "json_is_valid: accepts valid JSON object"

    local json='{"key": "value"}'
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept valid JSON object"
        return 1
    fi
}

test_json_is_valid_array() {
    log_test "json_is_valid: accepts valid JSON array"

    local json='["item1", "item2"]'
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept valid JSON array"
        return 1
    fi
}

test_json_is_valid_empty_object() {
    log_test "json_is_valid: accepts empty object"

    local json='{}'
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept empty object"
        return 1
    fi
}

test_json_is_valid_empty_array() {
    log_test "json_is_valid: accepts empty array"

    local json='[]'
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept empty array"
        return 1
    fi
}

test_json_is_valid_with_whitespace() {
    log_test "json_is_valid: accepts JSON with leading/trailing whitespace"

    local json='   {"key": "value"}   '
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept JSON with whitespace"
        return 1
    fi
}

test_json_is_valid_multiline() {
    log_test "json_is_valid: accepts multiline JSON"

    local json='{
        "key": "value"
    }'
    if json_is_valid "$json"; then
        return 0
    else
        _log_failure "Should accept multiline JSON"
        return 1
    fi
}

test_json_is_valid_rejects_plain_string() {
    log_test "json_is_valid: rejects plain string"

    local json='just a string'
    if json_is_valid "$json"; then
        _log_failure "Should reject plain string"
        return 1
    else
        return 0
    fi
}

test_json_is_valid_rejects_number() {
    log_test "json_is_valid: rejects bare number"

    local json='42'
    if json_is_valid "$json"; then
        _log_failure "Should reject bare number"
        return 1
    else
        return 0
    fi
}

test_json_is_valid_rejects_unclosed_object() {
    log_test "json_is_valid: rejects unclosed object"

    local json='{"key": "value"'
    if json_is_valid "$json"; then
        _log_failure "Should reject unclosed object"
        return 1
    else
        return 0
    fi
}

test_json_is_valid_rejects_unclosed_array() {
    log_test "json_is_valid: rejects unclosed array"

    local json='["item1", "item2"'
    if json_is_valid "$json"; then
        _log_failure "Should reject unclosed array"
        return 1
    else
        return 0
    fi
}

#===============================================================================
# DOUBLE-SOURCING PROTECTION
#===============================================================================

test_double_source_protection() {
    log_test "Double-sourcing: only loads once"

    # Check the loaded flag is set
    assert_equals "1" "$_KAPSIS_JSON_UTILS_LOADED" "Loaded flag should be set"

    # Source again (should be no-op)
    source "$KAPSIS_ROOT/scripts/lib/json-utils.sh"

    # Flag should still be 1
    assert_equals "1" "$_KAPSIS_JSON_UTILS_LOADED" "Loaded flag should still be 1 after double-source"
}

#===============================================================================
# EDGE CASES
#===============================================================================

test_json_get_string_unicode() {
    log_test "Edge case: string with unicode characters"

    local json='{"greeting": "Hello World"}'
    local result
    result=$(json_get_string "$json" "greeting")

    # Basic ASCII should work; unicode handling may vary
    assert_not_equals "" "$result" "Should extract string with unicode"
}

test_json_with_nested_structure() {
    log_test "Edge case: nested JSON structure"

    # Note: json-utils is designed for flat structures
    # Nested values won't be properly extracted, but shouldn't crash
    local json='{"outer": {"inner": "value"}}'
    local result
    result=$(json_get_string "$json" "inner")

    # The regex should find "inner": "value" within the nested structure
    assert_equals "value" "$result" "Should find key in nested structure"
}

test_json_get_string_with_special_key() {
    log_test "Edge case: key with underscore"

    local json='{"my_key": "my_value"}'
    local result
    result=$(json_get_string "$json" "my_key")

    assert_equals "my_value" "$result" "Should handle underscores in key"
}

test_json_array_of_objects() {
    log_test "Edge case: array of objects"

    local json='[{"name": "first"}, {"name": "second"}]'
    local result
    result=$(json_get_string "$json" "name")

    # Should return first match
    assert_equals "first" "$result" "Should extract from array of objects"
}

#===============================================================================
# INTEGRATION TESTS
#===============================================================================

test_roundtrip_escape_and_embed() {
    log_test "Integration: escape string and embed in JSON"

    local original=$'line with "quotes" and\nnewline'
    local escaped
    escaped=$(json_escape_string "$original")

    # Build JSON with escaped value
    local json="{\"message\": \"$escaped\"}"

    # Verify JSON is valid
    if ! json_is_valid "$json"; then
        _log_failure "Generated JSON should be valid"
        return 1
    fi

    return 0
}

test_status_json_pattern() {
    log_test "Integration: parse status.json-like structure"

    # This simulates the status.json format used in Kapsis
    local json='{
        "phase": "implementing",
        "progress": 75,
        "agent_id": "claude-abc123",
        "complete": false
    }'

    local phase
    phase=$(json_get_string "$json" "phase")
    assert_equals "implementing" "$phase" "Should extract phase"

    local progress
    progress=$(json_get_number "$json" "progress")
    assert_equals "75" "$progress" "Should extract progress"

    local agent_id
    agent_id=$(json_get_string "$json" "agent_id")
    assert_equals "claude-abc123" "$agent_id" "Should extract agent_id"

    local complete
    complete=$(json_get_bool "$json" "complete")
    assert_equals "false" "$complete" "Should extract complete flag"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    print_test_header "JSON Utilities (json-utils.sh)"

    # json_get_string tests
    run_test test_json_get_string_simple
    run_test test_json_get_string_with_spaces
    run_test test_json_get_string_empty
    run_test test_json_get_string_missing_key
    run_test test_json_get_string_with_numbers
    run_test test_json_get_string_compact
    run_test test_json_get_string_with_colons
    run_test test_json_get_string_first_of_multiple
    run_test test_json_get_string_multiline

    # json_get_number tests
    run_test test_json_get_number_integer
    run_test test_json_get_number_zero
    run_test test_json_get_number_negative
    run_test test_json_get_number_null
    run_test test_json_get_number_missing_key
    run_test test_json_get_number_compact
    run_test test_json_get_number_large

    # json_get_bool tests
    run_test test_json_get_bool_true
    run_test test_json_get_bool_false
    run_test test_json_get_bool_missing_key
    run_test test_json_get_bool_compact
    run_test test_json_get_bool_multiline

    # json_escape_string tests
    run_test test_json_escape_string_quotes
    run_test test_json_escape_string_backslash
    run_test test_json_escape_string_newline
    run_test test_json_escape_string_tab
    run_test test_json_escape_string_carriage_return
    run_test test_json_escape_string_combined
    run_test test_json_escape_string_empty
    run_test test_json_escape_string_no_escaping_needed

    # json_is_valid tests
    run_test test_json_is_valid_object
    run_test test_json_is_valid_array
    run_test test_json_is_valid_empty_object
    run_test test_json_is_valid_empty_array
    run_test test_json_is_valid_with_whitespace
    run_test test_json_is_valid_multiline
    run_test test_json_is_valid_rejects_plain_string
    run_test test_json_is_valid_rejects_number
    run_test test_json_is_valid_rejects_unclosed_object
    run_test test_json_is_valid_rejects_unclosed_array

    # Double-sourcing protection
    run_test test_double_source_protection

    # Edge cases
    run_test test_json_get_string_unicode
    run_test test_json_with_nested_structure
    run_test test_json_get_string_with_special_key
    run_test test_json_array_of_objects

    # Integration tests
    run_test test_roundtrip_escape_and_embed
    run_test test_status_json_pattern

    # Summary
    print_summary
}

main "$@"
