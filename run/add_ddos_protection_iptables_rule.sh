#!/bin/bash

# Author: Wade Barnes https://gist.github.com/WadeBarnes/
# Minor modifications: Sebastian Schmittner https://github.com/Echsecutor

usage () {
  cat <<-EOF

  Usage:

    This script adds a connection rate limit per IP adress to the iptables rules in order to prevent a DDOS attack.

    $0 [-d] <client_port> <overall_connlimit> [per_ip_connlimit] [conn_rate_limit] [conn_rate_period] [logging_level]

      Options:
        -d                  - Delete the corresponding rules.
                              Removes the rules corresponding to the supplied input parameters.
        -t                  - Test mode.  Prints out the list of input settings and exits.

      Input Parameters:
        client_port         - Required.  The node's client port.
        overall_connlimit   - Required.  The overall connection limit for all clients.
        per_ip_connlimit    - Optional.  The connection limit per IP address; defaults to 10.
        conn_rate_limit     - Optional.  The connection limit for connection rate limiting; default to -1, off.
        conn_rate_period    - Optional.  The period for connection rate limiting; defaults to 60 seconds.
        logging_level       - Optional.  If used, this should be set to a level such as 'debug' so they can 
                                         easily be filtered from the logs and included only as needed.
                                         Default is no logging.

        Example:
        $0 9702 15000

EOF
    exit 1
}

check_setup () {
  cat <<-EOF

    Warning: iptables and/or iptables-persistent is not installed, or permission denied.  Client connections limit is not set.

    Please ensure iptables and iptables-persistent are both installed and iptables-persistent is enabled, and try running with sudo.

    # To install iptables-persistent:
    sudo apt-get install -y iptables-persistent

    # Make sure services are enabled on Debian or Ubuntu using the systemctl command:
    sudo systemctl is-enabled netfilter-persistent.service

    # If not enable it:
    sudo systemctl enable netfilter-persistent.service

    # Get status:
    sudo systemctl status netfilter-persistent.service

EOF
    exit 1
}

print_settings() {
  if (( ${CONN_RATE_LIMIT_LIMIT} <= 0 || ${CONN_RATE_LIMIT_PERIOD} <= 0 )); then
    RATE_LIMIT_MESSAGE=" - Connection rate limiting is turned off."
  fi

  cat <<-EOF

  client_port:          ${DPORT}
  overall_connlimit:    ${OVER_ALL_CONN_LIMIT}
  per_ip_connlimit:     ${CONN_LIMIT_PER_IP}
  conn_rate_limit:      ${CONN_RATE_LIMIT_LIMIT} ${RATE_LIMIT_MESSAGE} 
  conn_rate_period:     ${CONN_RATE_LIMIT_PERIOD} ${RATE_LIMIT_MESSAGE}
  logging_level:        ${CONN_LOGGING_LEVEL:-Not set, (off) default}
  
  IP_TABLES_CHAIN:      ${IP_TABLES_CHAIN}

  OPERATION:            ${OPERATION}
  DELETE:               ${DELETE}
  TEST_MODE:            ${TEST_MODE}
EOF
}

LOG_CHAIN=LOG_CONN_REJECT
OPERATION="add_rule"
IP_TABLES_CHAIN=${IP_TABLES_CHAIN:-DOCKER-USER}

while getopts dth FLAG; do
  case $FLAG in
    d)
      OPERATION="delete_rule"
      DELETE=1
      ;;
    t)
      TEST_MODE=1
      ;;
    h)
      usage
      ;;
    \?)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

DPORT=${1}
OVER_ALL_CONN_LIMIT=${2}

# Default to 10 connections per IP.
CONN_LIMIT_PER_IP=${3:-10}

# Default: Rate limiting disabled; -1.
CONN_RATE_LIMIT_LIMIT=${4:--1}

# Default to a per minute rate limit.
CONN_RATE_LIMIT_PERIOD=${5:-60}

CONN_LOGGING_LEVEL=${6}

add() {
    if [ -z ${DELETE} ]; then
        return 0
    else
        return 1
    fi
}

delete() {
    if [ ! -z ${DELETE} ]; then
        return 0
    else
        return 1
    fi
}

rule_exists() {
    RULE="${1}"
    cmd="iptables -C ${RULE} 2>/dev/null 1>&2"
    # echo $cmd
    eval $cmd
    rtnCd=$?
    if (( ${rtnCd} == 0 )); then
        return 0
    else
        return 1
    fi
}

add_rule() {
    RULE="${1}"
    if ! rule_exists "${RULE}"; then
        cmd="iptables -A ${RULE}"
        # echo $cmd
        eval $cmd
    fi
}

delete_rule() {
    RULE="${1}"
    if rule_exists "${RULE}"; then
        cmd="iptables -D ${RULE}"
        # echo $cmd
        eval $cmd
    fi
}

save_rules() {
    su -c "iptables-save > /etc/iptables/rules.v4 && ip6tables-save > /etc/iptables/rules.v6"
}

disable_ipv6() {
    echo "Disabling IPv6 ..."
    ip6_conf_file="/etc/sysctl.d/60-custom-disable-ipv6.conf"
    mkdir -p ${ip6_conf_file%/*}

    cat <<-EOF > ${ip6_conf_file}
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    sysctl -p
    systemctl restart procps
}

enable_ipv6() {
    echo "Enabling IPv6 ..."
    ip6_conf_file="/etc/sysctl.d/60-custom-disable-ipv6.conf"

    if [ -f ${ip6_conf_file} ]; then
        rm ${ip6_conf_file}
    fi
    sysctl -p
    systemctl restart procps
}

if [ $# -lt 2 ]; then
    usage
fi

if [ ! -z ${TEST_MODE} ]; then
    print_settings
    exit 0
fi

# Check whether iptables installed and works
dpkg -s iptables 2>/dev/null 1>&2 && iptables -nL 2>/dev/null 1>&2 && dpkg -s iptables-persistent 2>/dev/null 1>&2
if [ $? -eq 0 ]; then

    if add; then
        echo "Adding iptable rules ..."
        # Create logging chain for rejected connections
        iptables -N ${LOG_CHAIN} 2>/dev/null 1>&2
    else
        echo "Removing iptable rules ..."
    fi

    # Make sure the previous default logging rule is removed.  It causes too much CPU overhead under load.
    RULE="${LOG_CHAIN} -j LOG --log-level warning --log-prefix \"connlimit: \""
    delete_rule "${RULE}"

    # Append a rule that sets log level and log prefix
    # Default to no logging unless a logging level is explicitly supplied.
    if [ ! -z ${CONN_LOGGING_LEVEL} ]; then
        RULE="${LOG_CHAIN} -j LOG --log-level ${CONN_LOGGING_LEVEL} --log-prefix \"connlimit: \""
        ${OPERATION} "${RULE}"
    fi

    # Append a rule that finally rejects connection
    RULE="${LOG_CHAIN} -p tcp -j REJECT --reject-with tcp-reset"
    ${OPERATION} "${RULE}"

    # Append a rule to limit the total number of simultaneous client connections
    RULE="${IP_TABLES_CHAIN} -p tcp --syn --dport ${DPORT} -m connlimit --connlimit-above ${OVER_ALL_CONN_LIMIT} --connlimit-mask 0 -j ${LOG_CHAIN}"
    ${OPERATION} "${RULE}"

    # Append a rule to limit the number connections per IP address
    RULE="${IP_TABLES_CHAIN} -p tcp -m tcp --dport ${DPORT} --tcp-flags FIN,SYN,RST,ACK SYN -m connlimit --connlimit-above ${CONN_LIMIT_PER_IP} --connlimit-mask 32 --connlimit-saddr -j ${LOG_CHAIN}"
    ${OPERATION} "${RULE}"

    # Append rules to rate limit connections
    if (( ${CONN_RATE_LIMIT_LIMIT} > 0 && ${CONN_RATE_LIMIT_PERIOD} > 0 )); then
        echo "Including settings for rate limiting ..."
        RULE="${IP_TABLES_CHAIN} -p tcp -m tcp --dport ${DPORT} -m conntrack --ctstate NEW -m recent --set --name DEFAULT --mask 255.255.255.255 --rsource"
        ${OPERATION} "${RULE}"
        RULE="${IP_TABLES_CHAIN} -p tcp -m tcp --dport ${DPORT} -m conntrack --ctstate NEW -m recent --update --seconds ${CONN_RATE_LIMIT_PERIOD} --hitcount ${CONN_RATE_LIMIT_LIMIT} --name DEFAULT --mask 255.255.255.255 --rsource -j ${LOG_CHAIN}"
        ${OPERATION} "${RULE}"
    else
        echo "Rate limiting is disabled, skipping settings for rate limiting ..."
    fi

    if delete; then
        # Remove logging chain for rejected connections
        iptables -X ${LOG_CHAIN} 2>/dev/null 1>&2
    fi

    # Save the rules
    save_rules

    if add; then
        disable_ipv6
    else
        enable_ipv6
    fi
else
    check_setup
fi