#!/bin/bash

RUNC_CMD="${RUNC_CMD:-sudo docker}"

BASE_IMAGE="ovn/cinc"
CENTRAL_IMAGE="ovn/ovn-multi-node"
CHASSIS_IMAGE="ovn/ovn-multi-node"
GW_IMAGE="ovn/ovn-multi-node"

CENTRAL_NAME="ovn-central"
CHASSIS_PREFIX="ovn-chassis-"
GW_PREFIX="ovn-gw-"

CHASSIS_COUNT=2
CHASSIS_NAMES=()

GW_COUNT=0
GW_NAMES=()

OVN_BR="br-ovn"
OVN_EXT_BR="br-ovn-ext"

OVS_DOCKER="./ovs-docker"

OVN_SRC_PATH="${OVN_SRC_PATH:-}"
OVS_SRC_PATH="${OVS_SRC_PATH:-}"

function check-selinux() {
  if [[ "$(getenforce)" = "Enforcing" ]]; then
    >&2 echo "Error: This script is not compatible with SELinux enforcing mode."
    exit 1
  fi
}

function count-central() {
    local filter=${1:-}
    count-containers "${CENTRAL_NAME}" "${filter}"
}

function count-chassis() {
    local filter=${1:-}
    count-containers "${CHASSIS_PREFIX}" "${filter}"
}

function count-gw() {
    local filter=${1:-}
    count-containers "${GW_PREFIX}" "${filter}"
}

function count-containers() {
  local name=$1
  local filter=${2:-}

  local count=0
  for cid in $( ${RUNC_CMD} ps -qa --filter "name=${name}" $filter); do
    (( count += 1 ))
  done

  echo "$count"
}

function check-no-containers {
  local operation=$1
  local filter=${2:-}
  local message="${3:-Existing cluster parts}"

  local existing_nodes existing_master
  existing_chassis=$(count-chassis "${filter}")
  existing_central=$(count-central "${filter}")
  existing_gws=$(count-gw "${filter}")
  if (( existing_chassis > 0 || existing_central > 0 || existing_gws > 0)); then
    echo
    echo "ERROR: Can't ${operation}.  ${message} (${existing_central} existing central or ${existing_chassis} existing chassis)"
    exit 1
  fi
}

function start-container() {
  local image=$1
  local name=$2

  local volumes run_cmd
  volumes=""

  ${RUNC_CMD} run -dt ${volumes} -v "/tmp/ovn-multinode:/data" --privileged \
                --name="${name}" --hostname="${name}" "${image}" > /dev/null
}

function stop() {
    echo "Stopping OVN cluster"
    # Delete the containers
    for cid in $( ${RUNC_CMD} ps -qa --filter "name=${CENTRAL_NAME}|${GW_PREFIX}|${CHASSIS_PREFIX}" ); do
       ${RUNC_CMD} rm -f "${cid}" > /dev/null
    done
}

function setup-ovs-in-host() {
    ovs-vsctl --if-exists del-br $OVN_BR || exit 1
    ovs-vsctl --if-exists del-br $OVN_EXT_BR || exit 1
    ovs-vsctl add-br $OVN_BR || exit 1
    ovs-vsctl add-br $OVN_EXT_BR || exit 1
}

function add-ovs-docker-ports() {
    ip_range="170.168.0"
    local ip_start="100"
    cidr="24"
    br=br-ovn
    eth=eth1

    ${OVS_DOCKER} add-port $br $eth ${CENTRAL_NAME} --ipaddress=${ip_range}.${ip_start}/${cidr}

    for name in "${GW_NAMES[@]}"; do
        (( ip_start += 1 ))
        ${OVS_DOCKER} add-port $br $eth ${name} --ipaddress=${ip_range}.${ip_start}/${cidr}
    done

    for name in "${CHASSIS_NAMES[@]}"; do
        (( ip_start += 1 ))
        ${OVS_DOCKER} add-port $br $eth ${name} --ipaddress=${ip_range}.${ip_start}/${cidr}
    done

    ${OVS_DOCKER} add-port br-ovn-ext eth2 ${CENTRAL_NAME}

    for name in "${GW_NAMES[@]}"; do
        ${OVS_DOCKER} add-port br-ovn-ext eth2 ${name}
    done

    for name in "${CHASSIS_NAMES[@]}"; do
        ${OVS_DOCKER} add-port br-ovn-ext eth2 ${name}
    done
}

function configure-ovn() {
    rm -f /tmp/ovn-multinode/configure_ovn.sh

    cat << EOF > /tmp/ovn-multinode/configure_ovn.sh
#!/bin/bash

eth=$1
ovn_remote=$2

if [ "\$eth" = "" ]; then
    eth=eth0
fi

ovn_remote=$2

if [ "\$ovn_remote" = "" ]; then
    ovn_remote="tcp:172.17.0.2:6642"
fi

ip=\`ip addr show \$eth | grep inet | grep -v inet6 | awk '{print \$2}' | cut -d'/' -f1\`

ovs-vsctl set open . external_ids:ovn-encap-ip=\$ip
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
ovs-vsctl set open . external-ids:ovn-remote=\$ovn_remote

ovs-vsctl --if-exists del-br br-ex
ovs-vsctl add-br br-ex
ovs-vsctl set open . external-ids:ovn-bridge-mappings=public:br-ex

ip link set eth2 down
ovs-vsctl add-port br-ex eth2
ip link set eth2 up
EOF

    chmod 0755 /tmp/ovn-multinode/configure_ovn.sh

    ${RUNC_CMD} exec ${CENTRAL_NAME} bash /data/configure_ovn.sh

    for name in "${GW_NAMES[@]}"; do
        ${RUNC_CMD} exec ${name} bash /data/configure_ovn.sh
    done

    for name in "${CHASSIS_NAMES[@]}"; do
        ${RUNC_CMD} exec ${name} bash /data/configure_ovn.sh
    done 
}

function start() {
    echo "Starting OVN cluster"

    # Check that no ovn related containers are running.
    check-no-containers "start"

    # docker-in-docker's use of volumes is not compatible with SELinux
    check-selinux

    setup-ovs-in-host

    # Ensuring compatible host configuration
    #
    # Running in a container ensures that the docker host will be affected even
    # if docker is running remotely.  The openshift/dind-node image was chosen
    # due to its having sysctl installed.
    ${RUNC_CMD} run --privileged --net=host --rm -v /lib/modules:/lib/modules \
                ${CENTRAL_IMAGE} bash -e -c \
                '/usr/sbin/modprobe openvswitch;
                /usr/sbin/modprobe overlay 2> /dev/null || true;'

    mkdir -p /tmp/ovn-multinode

    
    # Create containers
    start-container "${CENTRAL_IMAGE}" "${CENTRAL_NAME}"
    for name in "${GW_NAMES[@]}"; do
        start-container "${GW_IMAGE}" "${name}"
    done

    for name in "${CHASSIS_NAMES[@]}"; do
        start-container "${CHASSIS_IMAGE}" "${name}"
    done

    echo "Sleeping for 5 seconds"
    sleep 5

    echo "Adding ovs-ports"
    # Add ovs ports to each of the nodes.
    add-ovs-docker-ports

    # Start OVN db servers on central node
    ${RUNC_CMD} exec ${CENTRAL_NAME} /usr/share/ovn/scripts/ovn-ctl start_northd
    sleep 2
    ${RUNC_CMD} exec ${CENTRAL_NAME} ovn-nbctl set-connection ptcp:6641
    ${RUNC_CMD} exec ${CENTRAL_NAME} ovn-sbctl set-connection ptcp:6642

    # Start openvswitch and ovn-controller on each node
    ${RUNC_CMD} exec ${CENTRAL_NAME} /usr/share/openvswitch/scripts/ovs-ctl start --system-id=${CENTRAL_NAME}
    ${RUNC_CMD} exec ${CENTRAL_NAME} /usr/share/ovn/scripts/ovn-ctl start_controller

    for name in "${GW_NAMES[@]}"; do
        ${RUNC_CMD} exec ${name} /usr/share/openvswitch/scripts/ovs-ctl start --system-id=${name}
        ${RUNC_CMD} exec ${name} /usr/share/ovn/scripts/ovn-ctl start_controller
    done

    for name in "${CHASSIS_NAMES[@]}"; do
        ${RUNC_CMD} exec ${name} /usr/share/openvswitch/scripts/ovs-ctl start --system-id=${name}
        ${RUNC_CMD} exec ${name} /usr/share/ovn/scripts/ovn-ctl start_controller
    done

    configure-ovn
}

function build-images() {
    echo "OVN_SRC_PATH = $OVN_SRC_PATH"
    if [ "${OVN_SRC_PATH}" = "" ]; then
        echo "Set the OVN_SRC_PATH var pointing to the location of ovn source code."
        exit 1
    fi

    echo "OVS_SRC_PATH = $OVS_SRC_PATH"
    if [ "${OVS_SRC_PATH}" = "" ]; then
        echo "Set the OVS_SRC_PATH var pointing to the location of ovs source code."
        exit 1
    fi

    rm -rf ovn
    cp -rf $OVN_SRC_PATH ovn
    rm -rf ovs
    cp -rf $OVS_SRC_PATH ovs
    ${RUNC_CMD} build -t ovn/cinc -f Dockerfile .
    ${RUNC_CMD} build -t ovn/ovn-multi-node  --build-arg OVS_SRC_PATH=ovs --build-arg OVN_SRC_PATH=ovn -f fedora/Dockerfile .
    rm -rf ovn
    rm -rf ovs
}

case "${1:-""}" in
    start)
        while getopts ":abc:in:rsN:lm:" opt; do
            BUILD=
            BUILD_IMAGES=
            WAIT_FOR_CLUSTER=1
            REMOVE_EXISTING_CULSTER=
            ADDITIONAL_NETWORK_INTERFACE=
            case $opt in
            i)
                BUILD_IMAGES=1
                ;;
            C)
                CHASSIS_COUNT="${OPTARG}"
                ;;
            G)
                GW_COUNT="${OPTARG}"
                ;;
            r)
                REMOVE_EXISTING_CLUSTER=1
                ;;
            s)
                WAIT_FOR_CLUSTER=
                ;;
            c)
                CONTAINER_RUNTIME="${OPTARG}"
                ;;
            \?)
                echo "Invalid option: -${OPTARG}" >&2
                exit 1
            ;;
            :)
                echo "Option -${OPTARG} requires an argument." >&2
                exit 1
                ;;
            esac
        done

        for (( i=1; i<=CHASSIS_COUNT; i++ )); do
            CHASSIS_NAMES+=( "${CHASSIS_PREFIX}${i}" )
        done

        for (( i=1; i<=GW_COUNT; i++ )); do
            GW_NAMES+=( "${GW_PREFIX}${i}" )
        done

        if [[ -n "${REMOVE_EXISTING_CLUSTER}" ]]; then
            stop
        fi

        start
        ;;
    stop)
        stop;;
    build)
        build-images
        ;;
    esac

echo "Exiting.. Bye"
exit 0
