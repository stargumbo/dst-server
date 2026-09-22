#!/bin/bash
#
# Fixed-string redaction of the Klei cluster token in the shards' stdout/stderr.
# Fed by the entrypoint through a FIFO; one line in, one line out, flushed per line so
# `docker logs -f` stays live. The secret arrives in DST_REDACT_SECRET (never argv).
# The replacement is a quoted parameter-expansion pattern, so every character of the
# secret is literal: no regex, no globbing, metacharacters are fine.

secret="${DST_REDACT_SECRET:-}"
unset DST_REDACT_SECRET

while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${secret}" ]]; then
        line="${line//"${secret}"/****}"
    fi
    printf '%s\n' "${line}"
done
