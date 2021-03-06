#!/bin/sh

## ensure consul is yet not running - important due to supervisor restart
pkill consul

set -e

mkdir -p ${SERVER_CONFIG_STORE}
mkdir -p ${CLIENTS_SHARED_CONFIG_STORE}

#if [ -f ${SERVER_CONFIG_STORE}/.firstsetup ]; then
#	touch ${CLIENTS_SHARED_CONFIG_STORE}/.bootstrapped
#
#	# this is a moveable pointer, so in 2023 we will use .updatecerts2018 to regenerate all certificates since tey are valid for 5 years only
#	if [ ! -f ${SERVER_CONFIG_STORE}/.updatecerts2018 ]; then
#        server_tls.sh `hostname -f`
#	    touch ${SERVER_CONFIG_STORE}/.updatecerts2018
#    fi
#fi

if [ -z "${ENABLE_APK}" ]; then
	echo "disabled apk, hopefully you got all those things installed: bash curl jq openssl"
else
	apk update
	apk add bash curl jq openssl
fi

mkdir -p ${SERVER_CONFIG_STORE}

if [ -f ${SERVER_CONFIG_STORE}/.firstsetup ]; then
  echo "Server already bootstrapped"

  # try to converge
  current_acl_agent_token=$(cat ${SERVER_CONFIG_STORE}/server_acl_agent_acl_token.json | jq -r -M '.acl_agent_token')
  if [ -z "$ENABLE_ACL" ] || [ "$ENABLE_ACL" -eq "0" ]; then
    # deconfigure ACL, no longer present
    rm -f ${SERVER_CONFIG_STORE}/.aclanonsetup ${CLIENTS_SHARED_CONFIG_STORE}/general_acl_token.json ${SERVER_CONFIG_STORE}/server_acl_master_token.json ${SERVER_CONFIG_STORE}/server_acl_agent_acl_token.json
  elif [ ! -f ${SERVER_CONFIG_STORE}/.aclanonsetup ] || [ ! -f ${CLIENTS_SHARED_CONFIG_STORE}/general_acl_token.json ] ||  [ ! -f ${SERVER_CONFIG_STORE}/server_acl_master_token.json ] || [ ! -f ${SERVER_CONFIG_STORE}/server_acl_agent_acl_token.json ] || [ -z "${current_acl_agent_token}" ]; then
    echo "ACL is missconifgured / outdated, trying to fix it"
    # safe start the sever, configure ACL if needed and then start normally
    docker-entrypoint.sh "$@" -bind 127.0.0.1 &
    consul_pid="$!"
    echo "waiting for the server to come up..."
    wait-for-it -t 300 -h 127.0.0.1 -p 8500 --strict -- echo "..consul found" || (echo "error waiting for consul" && exit 1)
    sleep 5s
    server_acl.sh
    kill ${consul_pid}
    echo "wait for the local server to fully shutdown - 5 seconds, pid: ${consul_pid}"
    sleep 5s
  fi

   # normal startup
  exec docker-entrypoint.sh "$@"
else
  echo "--- First bootstrap of the server..configuring ACL/GOSSIP/TLS as configured"

  server_tls.sh `hostname -f`
  server_gossip.sh

  # enable ACL support before we start the server
  if [ -n "${ENABLE_ACL}" ] && [ ! "${ENABLE_ACL}" -eq "0" ] ; then
  	# this needs to be done before the server starts, we cannot move that into server_acl.sh
  	# locks down our consul server from leaking any data to anybody - full anon block
	cat > ${SERVER_CONFIG_STORE}/server_acl.json <<EOL
{
  "acl_datacenter": "stable",
  "acl_default_policy": "deny",
  "acl_down_policy": "deny"
}
EOL
  fi

  echo "---- Starting server in local 127.0.0.1 to not allow node registering during configuration"
  docker-entrypoint.sh "$@" -bind 127.0.0.1 &
  consul_pid="$!"
  echo "waiting for the server to come up..."
  wait-for-it -t 300 -h 127.0.0.1 -p 8500 --strict -- echo "..consul found" || (echo "error waiting for consul" && exit 1)
  echo "waiting further 15 seconds to ensure our server is fully bootstrapped"
  sleep 15s
  echo "continuing server boostrap after additional 15 seconds passed"
  server_acl.sh
  echo "--- shutting down 'local only' server and starting usual server, pid: ${consul_pid}"
  kill ${consul_pid}

  echo "wait for the local server to fully shutdown - 10 seconds"
  sleep 10s
  # that does secure we do not rerun this initial bootstrap configuration
  touch ${SERVER_CONFIG_STORE}/.firstsetup

  # tell our clients they can startup, finding the configuration they need on the shared volume
  touch ${CLIENTS_SHARED_CONFIG_STORE}/.bootstrapped
  # touch ${SERVER_CONFIG_STORE}/.updatecerts2018
  exec docker-entrypoint.sh "$@"
fi