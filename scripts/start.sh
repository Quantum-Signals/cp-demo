#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/helper/functions.sh
source ${DIR}/env.sh

#-------------------------------------------------------------------------------

# Do preflight checks
preflight_checks || exit

# Stop existing Docker containers
${DIR}/stop.sh

CLEAN=${CLEAN:-false}

# Build Kafka Connect image with connector plugins
#build_connect_image

# Set the CLEAN variable to true if cert doesn't exist
if ! [[ -f "${DIR}/security/controlCenterAndKsqlDBServer-ca1-signed.crt" ]]; then
  echo "INFO: Running with CLEAN=true because instructed or certificates don't yet exist."
  clean_demo_env
  CLEAN=true
fi

echo
echo "Environment parameters"
echo "  REPOSITORY=$REPOSITORY"
echo "  CONNECTOR_VERSION=$CONNECTOR_VERSION"
echo "  CLEAN=$CLEAN"
echo "  VIZ=$VIZ"
echo


if [[ "$CLEAN" == "true" ]] ; then
  create_certificates || exit 1
  #if [[ ! check_num_certs ]]; then
  #  echo -e "\nERROR: Expected ~147 trusted certificates on the Kafka Connect server but got 1. Please troubleshoot and try again."
  #  exit 1
  #fi
fi


#-------------------------------------------------------------------------------

# Bring up openldap

#FIXME: Hack in superUser password.
sed -i "s|\(userPassword *: *\).*|\1${SUPER_USER_PASSWORD}|" ${DIR}/security/ldap_users/13_superuser.ldif
sed -i "s|\(userPassword *: *\).*|\1${READONLY_USER_PASSWORD}|" ${DIR}/security/ldap_users/22_readonly.ldif

docker compose up --no-recreate -d openldap
sleep 5
if [[ $(docker compose ps openldap | grep Exit) =~ "Exit" ]] ; then
  echo "ERROR: openldap container could not start. Troubleshoot and try again. For troubleshooting instructions see https://docs.confluent.io/platform/current/tutorials/cp-demo/docs/troubleshooting.html"
  exit 1
fi



# Bring up tools
docker compose up --no-recreate -d tools

# Add root CA to container (obviates need for supplying it at CLI login '--ca-cert-path')
docker compose exec tools bash -c "cp /etc/kafka/secrets/snakeoil-ca-1.crt /usr/local/share/ca-certificates && /usr/sbin/update-ca-certificates"


# Bring up base kafka cluster
docker compose up --no-recreate -d kafka1

# Verify MDS has started
MAX_WAIT=150
echo "Waiting up to $MAX_WAIT seconds for MDS to start"
retry $MAX_WAIT host_check_up kafka1 || exit 1

echo "Creating role bindings for principals"
docker compose exec tools bash -c "/tmp/helper/create-role-bindings.sh" || exit 1

# Workaround for setting min ISR on topic _confluent-metadata-auth
docker compose exec kafka1 kafka-configs \
   --bootstrap-server kafka1:12091 \
   --entity-type topics \
   --entity-name _confluent-metadata-auth \
   --alter \
   --add-config min.insync.replicas=1

#-------------------------------------------------------------------------------


# Bring up more containers
docker compose up --no-recreate -d schemaregistry control-center node-exporter

echo
echo -e "Create topics in Kafka cluster:"
docker compose exec tools bash -c "/tmp/helper/create-topics.sh" || exit 1

#-------------------------------------------------------------------------------

# Verify Confluent Control Center has started
MAX_WAIT=300
echo
echo "Waiting up to $MAX_WAIT seconds for Confluent Control Center to start"
retry $MAX_WAIT host_check_up control-center || exit 1

echo -e "\nConfluent Control Center modifications:"
${DIR}/helper/control-center-modifications.sh
echo


#-------------------------------------------------------------------------------


# Verify Docker containers started
if [[ $(docker compose ps) =~ "Exit 137" ]]; then
  echo -e "\nERROR: At least one Docker container did not start properly, see 'docker compose ps'. Did you increase the memory available to Docker to at least 8 GB (default is 2 GB)?\n"
  exit 1
fi

echo
echo -e "\nAvailable LDAP users:"
#docker compose exec openldap ldapsearch -x -h localhost -b dc=confluentdemo,dc=io -D "cn=admin,dc=confluentdemo,dc=io" -w admin | grep uid:
curl -u mds:mds -X POST "https://localhost:8091/security/1.0/principals/User%3Amds/roles/UserAdmin" \
  -H "accept: application/json" -H "Content-Type: application/json" \
  -d "{\"clusters\":{\"kafka-cluster\":\"does_not_matter\"}}" \
  --cacert ${DIR}/security/snakeoil-ca-1.crt --tlsv1.2
curl -u mds:mds -X POST "https://localhost:8091/security/1.0/rbac/principals" --silent \
  -H "accept: application/json"  -H "Content-Type: application/json" \
  -d "{\"clusters\":{\"kafka-cluster\":\"does_not_matter\"}}" \
  --cacert ${DIR}/security/snakeoil-ca-1.crt --tlsv1.2 | jq '.[]'

# Do poststart_checks
poststart_checks


cat << EOF

----------------------------------------------------------------------------------------------------
DONE! From your browser:

  Confluent Control Center (login superUser/\$SUPER_USER_PASSWORD for full access):
     $C3URL

Want more? Learn how to replicate data from the on-prem cluster to Confluent Cloud:

     https://docs.confluent.io/platform/current/tutorials/cp-demo/docs/hybrid-cloud.html

Use Confluent Cloud promo code CPDEMO50 to receive \$50 free usage
----------------------------------------------------------------------------------------------------

EOF
