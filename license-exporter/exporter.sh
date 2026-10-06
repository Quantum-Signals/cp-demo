#!/bin/sh

# Minimal Prometheus exporter for the Confluent license status.
#
# Reads the license topic with kcat every CHECK_INTERVAL seconds and writes the
# result to a static metrics file served by busybox httpd. A trial license is
# stored as a JWT in _confluent-command; the developer ("free tier") license is
# never stored, so "no stored license" means developer license.
# See debug/findings.txt and scripts/license-check.sh.

KAFKA_BOOTSTRAP=${KAFKA_BOOTSTRAP:-kafka1:12091}
LICENSE_TOPIC=${LICENSE_TOPIC:-_confluent-command}
CHECK_INTERVAL=${CHECK_INTERVAL:-300}
PORT=${PORT:-9101}
WWW=/www

#-------------------------------------------------------------------------------

b64url_decode() {
  p=$(echo "$1" | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  echo "$p" | base64 -d 2>/dev/null
}

check() {
  trial=0 stored=0 expiry="" success=0

  if dump=$(timeout 60 kcat -C -b "$KAFKA_BOOTSTRAP" -t "$LICENSE_TOPIC" \
      -o beginning -e -q -m 30 2>/dev/null); then
    success=1
    # Records are binary protobuf: keep only JWT-safe characters, last token wins
    token=$(printf '%s' "$dump" | tr -c 'A-Za-z0-9._-' '\n' \
      | grep -oE 'eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -n 1)
    if [ -n "$token" ]; then
      stored=1
      payload=$(b64url_decode "$(echo "$token" | cut -d. -f2)")
      type=$(echo "$payload" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4)
      expiry=$(echo "$payload" | grep -o '"exp":[0-9]*' | cut -d: -f2)
      [ "$type" = "trial" ] && trial=1
    fi
  fi

  {
    echo "# HELP confluent_license_trial 1 if a trial license is stored in $LICENSE_TOPIC."
    echo "# TYPE confluent_license_trial gauge"
    echo "confluent_license_trial $trial"
    echo "# HELP confluent_license_stored 1 if any license record is stored (0 = developer license)."
    echo "# TYPE confluent_license_stored gauge"
    echo "confluent_license_stored $stored"
    if [ -n "$expiry" ]; then
      echo "# HELP confluent_license_expiry_timestamp_seconds Expiry of the stored license."
      echo "# TYPE confluent_license_expiry_timestamp_seconds gauge"
      echo "confluent_license_expiry_timestamp_seconds $expiry"
    fi
    echo "# HELP confluent_license_check_success 1 if the license topic could be read."
    echo "# TYPE confluent_license_check_success gauge"
    echo "confluent_license_check_success $success"
    echo "# HELP confluent_license_last_check_timestamp_seconds Time of the last check."
    echo "# TYPE confluent_license_last_check_timestamp_seconds gauge"
    echo "confluent_license_last_check_timestamp_seconds $(date +%s)"
  } > "$WWW/metrics.tmp" && mv "$WWW/metrics.tmp" "$WWW/metrics"
}

#-------------------------------------------------------------------------------

mkdir -p "$WWW"
check
httpd -p "$PORT" -h "$WWW" || exit 1

while true; do
  sleep "$CHECK_INTERVAL"
  check
done
