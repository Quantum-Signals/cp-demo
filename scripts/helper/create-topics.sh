#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/functions.sh

KAFKA_CLUSTER_ID=$(get_kafka_cluster_id_from_container)

auth="superUser:${SUPER_USER_PASSWORD}"

create_topic kafka1:8091 ${KAFKA_CLUSTER_ID} users true ${auth}

for TOPIC in ${INIT_TOPICS}; do
	create_topic kafka1:8091 ${KAFKA_CLUSTER_ID} ${TOPIC} true ${auth}
done