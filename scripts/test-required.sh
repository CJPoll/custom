#!/usr/bin/env bash

set -e

source "${HOME}/dev/custom/scripts/shell-base"

# Define required variables
REQUIRED_VARS=("CONFIG_FILE" "OUTPUT_DIR")

# Only set one of them
CONFIG_FILE="/tmp/config.ini"
# OUTPUT_DIR is intentionally not set

ARGUMENT_VARS=("-c" "--config" "-o" "--output")

function handle_argument() {
    case "${1}" in
        -c|--config)
            validate_argument CONFIG_FILE "${2}"
            ;;
        -o|--output)
            validate_argument OUTPUT_DIR "${2}"
            ;;
        -*|--*)
            echo "Error: Unsupported flag ${1}" >&2
            exit 4
            ;;
        *)
            PARAMS="$PARAMS ${1}"
            ;;
    esac
}

function script() {
    echo "Config: $CONFIG_FILE"
    echo "Output: $OUTPUT_DIR"
}

main "$@"