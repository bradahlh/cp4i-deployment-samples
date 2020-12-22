#!/bin/bash
#******************************************************************************
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2020. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#******************************************************************************

#******************************************************************************
# PREREQUISITES:
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# PARAMETERS:
#   -n : <POSTGRES_NAMESPACE> (string), Defaults to 'cp4i'
#   -m : <metadata_name> (string)
#   -u : <metadata_uid> (string)
#
# USAGE:
#   ./release-psql.sh
#
#   To add ownerReferences for the demos operator
#     ./release-ar.sh -m metadata_name -u metadata_uid

#******************************************************************************

function usage() {
  echo "Usage: $0 -n <POSTGRES_NAMESPACE>"
  exit 1
}

POSTGRES_NAMESPACE="cp4i"

while getopts "n:m:u:" opt; do
  case ${opt} in
  n)
    POSTGRES_NAMESPACE="$OPTARG"
    ;;
  m)
    metadata_name="$OPTARG"
    ;;
  u)
    metadata_uid="$OPTARG"
    ;;
  \?)
    usage
    ;;
  esac
done

CURRENT_DIR=$(dirname $0)
CURRENT_DIR_WITHOUT_DOT_SLASH=${CURRENT_DIR//.\//}

echo -e "Postgres namespace for release-psql: '$POSTGRES_NAMESPACE'\n"

echo "Installing PostgreSQL..."
cat <<EOF >/tmp/postgres.env
  MEMORY_LIMIT=2Gi
  NAMESPACE=openshift
  DATABASE_SERVICE_NAME=postgresql
  POSTGRESQL_USER=admin
  POSTGRESQL_DATABASE=sampledb
  VOLUME_CAPACITY=1Gi
  POSTGRESQL_VERSION=10
EOF

oc create namespace ${POSTGRES_NAMESPACE}

echo "checking tmp dir"

ls -al /tmp

if [[ ! -z ${metadata_uid} && ! -z ${metadata_name} ]]; then
echo "INFO: oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env > /tmp/postgres.json
jq '.items[3].metadata += {"ownerReferences": [{"apiVersion": "integration.ibm.com/v1beta1", "kind": "Demo", "name": "$metadata_name", "uid": "$metadata_uid"}]}' /tmp/postgres.json
oc apply -n ${POSTGRES_NAMESPACE} -f /tmp/postgres.json"
oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env > /tmp/postgres.json
jq '.items[3].metadata += {"ownerReferences": [{"apiVersion": "integration.ibm.com/v1beta1", "kind": "Demo", "name": "$metadata_name", "uid": "$metadata_uid"}]}' /tmp/postgres.json > /tmp/postgres-owner-ref.json
oc apply -n ${POSTGRES_NAMESPACE} -f /tmp/postgres-owner-ref.json
else
echo "INFO: oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env | oc apply -n ${POSTGRES_NAMESPACE} -f -"
oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env | oc apply -n ${POSTGRES_NAMESPACE} -f -
fi

echo "INFO: Waiting for postgres to be ready in the ${POSTGRES_NAMESPACE} namespace"
oc wait -n ${POSTGRES_NAMESPACE} --for=condition=available --timeout=20m deploymentconfig/postgresql

DB_POD=$(oc get pod -n ${POSTGRES_NAMESPACE} -l name=postgresql -o jsonpath='{.items[].metadata.name}')
echo "INFO: Found DB pod as: ${DB_POD}"

echo "INFO: Changing DB parameters for Debezium support"
oc exec -n ${POSTGRES_NAMESPACE} -i $DB_POD \
-- psql <<EOF
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_wal_senders=10;
ALTER SYSTEM SET max_replication_slots=10;
EOF

echo "INFO: Restarting postgres to pick up the parameter changes"
oc rollout latest -n ${POSTGRES_NAMESPACE} dc/postgresql

echo "INFO: Waiting for postgres to restart"
sleep 30
oc wait -n ${POSTGRES_NAMESPACE} --for=condition=available --timeout=20m deploymentconfig/postgresql

DB_POD=$(oc get pod -n ${POSTGRES_NAMESPACE} -l name=postgresql -o jsonpath='{.items[].metadata.name}')
echo "INFO: Found new DB pod as: ${DB_POD}"
