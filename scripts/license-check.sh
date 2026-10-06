#!/bin/bash

# Report the Confluent license status of the running stack.
#
# A developer ("Free Tier", single broker) license is never stored; it is derived
# at runtime from the broker count. Trial and enterprise licenses are stored as a
# CONFLUENT_LICENSE record in the _confluent-command topic. So:
#   - no license record     -> developer license (unlimited)
#   - license record found  -> decoded and reported, including expiry
#
# Exit codes: 0 = OK, 1 = stored license expired, 2 = could not read the topic

KAFKA_CONTAINER=${KAFKA_CONTAINER:-kafka1}
BOOTSTRAP=${BOOTSTRAP:-kafka1:12091}
LICENSE_TOPIC=_confluent-command

#-------------------------------------------------------------------------------

b64url_decode() {
  local p=$(echo "$1" | tr '_-' '/+')
  while (( ${#p} % 4 != 0 )); do p="$p="; done
  echo "$p" | base64 -d 2>/dev/null
}

json_field() {
  # Minimal extraction of a flat string/number/bool field from the JWT payload
  echo "$1" | grep -o "\"$2\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '"'
}

fmt_date() {
  [[ -n "$1" ]] && date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC'
}

#-------------------------------------------------------------------------------

echo "Source: topic $LICENSE_TOPIC on $KAFKA_CONTAINER ($BOOTSTRAP)"
offsets=$(docker exec $KAFKA_CONTAINER kafka-get-offsets \
  --bootstrap-server $BOOTSTRAP --topic $LICENSE_TOPIC 2>&1)
if ! [[ "$offsets" =~ ^${LICENSE_TOPIC}:[0-9]+:[0-9]+ ]]; then
  echo "ERROR: Could not read $LICENSE_TOPIC:"
  echo "$offsets" | head -5
  exit 2
fi
echo "Records: ${offsets##*:} (end offset)"

dump=$(docker exec $KAFKA_CONTAINER kafka-console-consumer \
  --bootstrap-server $BOOTSTRAP --topic $LICENSE_TOPIC \
  --from-beginning --timeout-ms 10000 2>/dev/null | tr -d '\0')
echo

# A JWT only appears in CONFLUENT_LICENSE records. Keep topic order (last one wins).
tokens=$(echo "$dump" | grep -ao 'eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | awk '!seen[$0]++')

if [[ -z "$tokens" ]]; then
  echo "License: no stored license record -> developer / Free Tier license (no expiry)"
  status=0
else
  count=$(echo "$tokens" | wc -l)
  now=$(date +%s)
  i=0
  status=0
  while read -r token; do
    i=$((i+1))
    payload=$(b64url_decode "$(echo "$token" | cut -d. -f2)")
    type=$(json_field "$payload" licenseType)
    exp=$(json_field "$payload" exp)

    label="License record $i of $count"
    (( i == count )) && label="$label (current)"
    echo "$label:"
    echo "  type:     ${type:-unknown} (audience: $(json_field "$payload" aud))"
    echo "  subject:  $(json_field "$payload" sub)"
    echo "  issued:   $(fmt_date "$(json_field "$payload" iat)")"
    if [[ -n "$exp" ]]; then
      days=$(( (exp - now) / 86400 ))
      if (( exp <= now )); then
        echo "  expires:  $(fmt_date "$exp")  -> EXPIRED"
        (( i == count )) && status=1
      else
        echo "  expires:  $(fmt_date "$exp")  -> $days days left"
      fi
    else
      echo "  expires:  never"
    fi
    echo "  payload:  $payload"
    echo
  done <<< "$tokens"
fi

# What the broker currently says, as a cross-check
echo
echo "Latest $KAFKA_CONTAINER license log line:"
docker logs --since 24h $KAFKA_CONTAINER 2>&1 \
  | grep -E 'io.confluent.license.(LicenseManager|validator)' | tail -1 \
  | sed 's/^/  /'

exit $status
