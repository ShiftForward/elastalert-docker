#!/bin/sh

set -e

# Set schema and elastalert options
case "${ELASTICSEARCH_TLS}:${ELASTICSEARCH_TLS_VERIFY}" in
    True:True)
        WGET_SCHEMA='https://'
        WGET_OPTIONS='-q -T 3'
        CREATE_EA_OPTIONS='--ssl --verify-certs'
    ;;
    True:False)
        WGET_SCHEMA='https://'
        WGET_OPTIONS='-q -T 3 --no-check-certificate'
        CREATE_EA_OPTIONS='--ssl --no-verify-certs'
    ;;
    *)
        WGET_SCHEMA='http://'
        WGET_OPTIONS='-q -T 3'
        CREATE_EA_OPTIONS='--no-ssl'
    ;;
esac

# Set the timezone.
if [ "$SET_CONTAINER_TIMEZONE" = "True" ]; then
    cp /usr/share/zoneinfo/${CONTAINER_TIMEZONE} /etc/localtime && \
    echo "${CONTAINER_TIMEZONE}" >  /etc/timezone && \
    echo "Container timezone set to: $CONTAINER_TIMEZONE"
else
    echo "Container timezone not modified"
fi

# Elastalert configuration:
if [ ! -f ${ELASTALERT_CONFIG} ]; then
    cp "${ELASTALERT_HOME}/config.yaml.example" "${ELASTALERT_CONFIG}" && \

    # Set the rule directory in the Elastalert config file to external rules directory.
    sed -i -e"s|rules_folder: [[:print:]]*|rules_folder: ${RULES_DIRECTORY}|g" "${ELASTALERT_CONFIG}"
    # Set the Elasticsearch host that Elastalert is to query.
    sed -i -e"s|es_host: [[:print:]]*|es_host: ${ELASTICSEARCH_HOST}|g" "${ELASTALERT_CONFIG}"
    # Set the port used by Elasticsearch at the above address.
    sed -i -e"s|es_port: [0-9]*|es_port: ${ELASTICSEARCH_PORT}|g" "${ELASTALERT_CONFIG}"
    # Set whether Elasticsearch should be accessed using SSL.
    if [ -n "${ELASTICSEARCH_TLS}" ]; then
        sed -i -e"s|#use_ssl: [[:print:]]*|use_ssl: ${ELASTICSEARCH_TLS}|g" "${ELASTALERT_CONFIG}"
    fi
    # Set whether to verify SSL certificates.
    if [ -n "${ELASTICSEARCH_TLS_VERIFY}" ]; then
        sed -i -e"s|#verify_certs: [[:print:]]*|verify_certs: ${ELASTICSEARCH_TLS}|g" "${ELASTALERT_CONFIG}"
    fi
    # Set the user name used to authenticate with Elasticsearch.
    if [ -n "${ELASTICSEARCH_USER}" ]; then
        sed -i -e"s|#es_username: [[:print:]]*|es_username: ${ELASTICSEARCH_USER}|g" "${ELASTALERT_CONFIG}"
    fi
    # Set the password used to authenticate with Elasticsearch.
    if [ -n "${ELASTICSEARCH_PASSWORD}" ]; then
        sed -i -e"s|#es_password: [[:print:]]*|es_password: ${ELASTICSEARCH_PASSWORD}|g" "${ELASTALERT_CONFIG}"
    fi
    # Set the writeback index used with elastalert.
    sed -i -e"s|writeback_index: [[:print:]]*|writeback_index: ${ELASTALERT_INDEX}|g" "${ELASTALERT_CONFIG}"
fi

# Replace env-vars
if [ -f ${ELASTALERT_CONFIG} ]; then
    envsubst < ${ELASTALERT_CONFIG} > ${ELASTALERT_CONFIG}.tmp
    mv ${ELASTALERT_CONFIG}.tmp ${ELASTALERT_CONFIG}
fi

# Elastalert Supervisor configuration:
if [ ! -f ${ELASTALERT_SUPERVISOR_CONF} ]; then
    cp "${ELASTALERT_HOME}/supervisord.conf.example" "${ELASTALERT_SUPERVISOR_CONF}" && \

    # Redirect Supervisor log output to a file in the designated logs directory.
    sed -i -e"s|logfile=.*log|logfile=${LOG_DIR}/elastalert_supervisord.log|g" "${ELASTALERT_SUPERVISOR_CONF}"
    # Redirect Supervisor stderr output to a file in the designated logs directory.
    sed -i -e"s|stderr_logfile=.*log|stderr_logfile=${LOG_DIR}/elastalert_stderr.log|g" "${ELASTALERT_SUPERVISOR_CONF}"
    # Modify the start-command.
    sed -i -e"s|python elastalert.py|elastalert --config ${ELASTALERT_CONFIG}|g" "${ELASTALERT_SUPERVISOR_CONF}"
fi

# Replace env-vars
if [ -f ${ELASTALERT_SUPERVISOR_CONF} ]; then
    envsubst < ${ELASTALERT_SUPERVISOR_CONF} > ${ELASTALERT_SUPERVISOR_CONF}.tmp
    mv ${ELASTALERT_SUPERVISOR_CONF}.tmp ${ELASTALERT_SUPERVISOR_CONF}
fi

# Set authentication if needed
if [ -n "$ELASTICSEARCH_USER" ] && [ -n "$ELASTICSEARCH_PASSWORD" ]; then
    WGET_AUTH="$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD@"
else
    WGET_AUTH=""
fi

# Wait until Elasticsearch is online since otherwise Elastalert will fail.
while ! wget ${WGET_OPTIONS} -O - "${WGET_SCHEMA}${WGET_AUTH}${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}" 2>/dev/null
do
    echo "Waiting for Elasticsearch..."
    sleep 1
done
sleep 5

# Check if the Elastalert index exists in Elasticsearch and create it if it does not.
if ! wget ${WGET_OPTIONS} -O - "${WGET_SCHEMA}${WGET_AUTH}${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/${ELASTALERT_INDEX}" 2>/dev/null
then
    echo "Creating Elastalert index in Elasticsearch..."
    elastalert-create-index ${CREATE_EA_OPTIONS} \
        --host "${ELASTICSEARCH_HOST}" \
        --port "${ELASTICSEARCH_PORT}" \
        --config "${ELASTALERT_CONFIG}" \
        --index "${ELASTALERT_INDEX}" \
        --old-index ""
else
    echo "Elastalert index already exists in Elasticsearch."
fi

echo "Starting Elastalert..."
exec supervisord -c "${ELASTALERT_SUPERVISOR_CONF}" -n
