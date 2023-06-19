#!/bin/bash

DEFAULT_KONG_IMAGE_REPO="kong"
DEFAULT_KONG_IMAGE_NAME="kong-gateway"
DEFAULT_KONG_IMAGE_TAG="3.3.0.0"

DEFAULT_POSTGRES_IMAGE_TAG="9.6"
DEFAULT_POSTGRES_IMAGE_NAME="postgres"

DEFAULT_KONG_PASSWORD=kongFTW

DEFAULT_APP_NAME="kong-quickstart"

DEFAULT_PROXY_PORT=8000
DEFAULT_ADMIN_PORT=8001
DEFAULT_MANAGER_PORT=8002
DEFAULT_DEVPORTAL_PORT=8003
DEFAULT_FILES_PORT=8004

KONG_IMAGE_REPO="${KONG_IMAGE_REPO:-$DEFAULT_KONG_IMAGE_REPO}"
KONG_IMAGE_NAME="${KONG_IMAGE_NAME:-$DEFAULT_KONG_IMAGE_NAME}"
KONG_IMAGE_TAG="${KONG_IMAGE_TAG:-$DEFAULT_KONG_IMAGE_TAG}"

POSTGRES_IMAGE_NAME="${POSTGRES_IMAGE_NAME:-$DEFAULT_POSTGRES_IMAGE_NAME}"
POSTGRES_IMAGE_TAG="${POSTGRES_IMAGE_TAG:-$DEFAULT_POSTGRES_IMAGE_TAG}"
POSTGRES_IMAGE="${POSTGRES_IMAGE_NAME}:${POSTGRES_IMAGE_TAG}"

POSTGRES_DB="${POSTGRES_DB:-kong}"
POSTGRES_USER="${POSTGRES_USER:-kong}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-kong}"

USE_DEFAULT_PORTS="true"

INSTALL_MOCK_SERVICE="${INSTALL_MOCK_SERVICE:-false}"

APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"
DB_NAME="${APP_NAME}-database"
GW_NAME="${APP_NAME}-gateway"

PROXY_PORT="${PROXY_PORT:-$DEFAULT_PROXY_PORT}"

ADMIN_PORT="${ADMIN_PORT:-$DEFAULT_ADMIN_PORT}"
MANAGER_PORT="${MANAGER_PORT:-$DEFAULT_MANAGER_PORT}"
DEVPORTAL_PORT="${DEVPORTAL_PORT:-$DEFAULT_DEVPORTAL_PORT}"
FILES_PORT="${FILE_PORT:-$DEFAULT_FILES_PORT}"

UNKNOWN_PORT_BIND_LIST=()

ENVIRONMENT=()
VOLUMES=()

ADMIN_API_HEADERS=()

DB_LESS_MODE="false"

echo_fail() {
  printf "\e[31m✘ \033\e[0m$@\n"
}

echo_pass() {
  printf "\e[32m✔ \033\e[0m$@\n"
}

echo_warn() {
  printf "\e[33m✋ \033\e[0m$@\n"
}

retry() {
    local -r -i max_wait="$1"; shift
    local -r cmd="$@"

    local -i sleep_interval=2
    local -i curr_wait=0

    until $cmd
    do
        if (( curr_wait >= max_wait ))
        then
            echo "ERROR: Command '${cmd}' failed after $curr_wait seconds."
            return 1
        else
            curr_wait=$((curr_wait+sleep_interval))
            sleep $sleep_interval
        fi
    done
}

curl_with_fail() {
  declare -i rv=0
  local OUTPUT_FILE=$(mktemp)
  declare -a cmd=( curl -L --silent --output "$OUTPUT_FILE" --write-out "%{http_code}" "$@" )
  local HTTP_CODE=$("${cmd[@]}")
  if [[ ${HTTP_CODE} -lt 200 || ${HTTP_CODE} -gt 299 ]] ; then
    rv=22
  fi
  cat $OUTPUT_FILE >> $LOG_FILE
  rm $OUTPUT_FILE
  echo "rv=$rv"
  return $rv
}

ensure_docker() {
  {
    docker ps -q > /dev/null 2>&1
  } || {
    return 1
  }
}
docker_pull_images() {
  echo ">docker_pull_images" >> $LOG_FILE
  echo Downloading Docker images
  docker pull ${POSTGRES_IMAGE} >> $LOG_FILE 2>&1 && docker pull ${KONG_IMAGE} >> $LOG_FILE 2>&1 && echo_pass "Images ready"
  local rv=$?
  echo "<docker_pull_images" >> $LOG_FILE
  return $rv
}

destroy_kong() {
  echo ">destroy_kong" >> $LOG_FILE
  echo Destroying previous $APP_NAME containers
  docker rm -f $GW_NAME >> $LOG_FILE 2>&1
  docker rm -f $DB_NAME >> $LOG_FILE 2>&1
  docker network rm $APP_NAME-net >> $LOG_FILE 2>&1
  echo "<destroy_kong" >> $LOG_FILE
}

init() {
  echo ">init" >> $LOG_FILE
  docker network create $APP_NAME-net >> $LOG_FILE 2>&1
  local rv=$?
  echo "<init" >> $LOG_FILE
  return $rv
}

wait_for_kong() {
  echo ">wait_for_kong" >> $LOG_FILE
  local rv=0
  retry 30 docker exec $GW_NAME kong health --v >> $LOG_FILE 2>&1 && echo_pass "Kong is healthy" || rv=$?
  echo "<wait_for_kong" >> $LOG_FILE
}

init_db() {
  echo ">init_db" >> $LOG_FILE
  local rv=0
  docker run --rm --network="${APP_NAME}-net" -e "KONG_DATABASE=postgres" --env-file "${APP_NAME}.env" "${VOLUMES[@]}" ${KONG_IMAGE} kong migrations bootstrap >> $LOG_FILE 2>&1
  rv=$?
  echo "<init_db" >> $LOG_FILE
  return $rv
}

wait_for_db() {
  echo ">wait_for_db" >> $LOG_FILE
  local rv=0
  retry 30 docker exec $DB_NAME pg_isready >> $LOG_FILE 2>&1 && echo_pass "Database is ready" || rv=$?
  echo "<wait_for_db" >> $LOG_FILE
  return $rv
}

db() {
  echo ">db" >> $LOG_FILE
  echo Starting database
  local db_port=0
  # not certain why, but the 1 second sleep seems required to allow the socket to fully open and db to be ready
  docker run -d --name "${DB_NAME}" --network="${APP_NAME}-net" -e "POSTGRES_DB=${POSTGRES_DB}" -e "POSTGRES_USER=${POSTGRES_USER}" -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" ${POSTGRES_IMAGE} >> $LOG_FILE 2>&1 && wait_for_db && sleep 1 && init_db
  local rv=$?
  echo "<db" >> $LOG_FILE
  return $rv
}

kong() {
  echo ">kong" >> $LOG_FILE
  echo Starting Kong

  if [ "$USE_DEFAULT_PORTS" = true ]; then
    local proxy_port_bind="-p ${PROXY_PORT}:${DEFAULT_PROXY_PORT}"
    local admin_port_bind="-p ${ADMIN_PORT}:${DEFAULT_ADMIN_PORT}"
    local manager_port_bind="-p ${MANAGER_PORT}:${DEFAULT_MANAGER_PORT}"
    local devportal_port_bind="-p ${DEVPORTAL_PORT}:${DEFAULT_DEVPORTAL_PORT}"
    local files_port_bind="-p ${FILES_PORT}:${DEFAULT_FILES_PORT}"
    docker run --privileged -d --name $GW_NAME --network=$APP_NAME-net --env-file "${APP_NAME}.env" ${proxy_port_bind} ${admin_port_bind} ${manager_port_bind} ${devportal_port_bind} ${files_port_bind} "${UNKNOWN_PORT_BIND_LIST[@]}" "${VOLUMES[@]}" ${KONG_IMAGE} >> $LOG_FILE 2>&1 && wait_for_kong && sleep 2
  else
    docker run --privileged -d --name $GW_NAME --network=$APP_NAME-net --env-file "${APP_NAME}.env" "${VOLUMES[@]}" -P ${KONG_IMAGE} >> $LOG_FILE 2>&1 && wait_for_kong && sleep 2
  fi

  local rv=$?
  echo "<kong" >> $LOG_FILE
  return $rv
}

get_dataplane_port() {
  local endpoint=$(docker port $GW_NAME 8000/tcp 2>/dev/null)
  if [ $? -eq 0 ];
  then
    local arrIN=(${endpoint//:/ })
    echo ${arrIN[1]}
  else
    echo ""
  fi
}
get_admin_port() {
  local endpoint=$(docker port $GW_NAME 8001/tcp 2>/dev/null)
  if [ $? -eq 0 ];
  then
    local arrIN=(${endpoint//:/ })
    echo ${arrIN[1]}
  else
    echo ""
  fi
}
get_manager_port() {
  local endpoint=$(docker port $GW_NAME 8002/tcp 2>/dev/null)
  if [ $? -eq 0 ];
  then
    local arrIN=(${endpoint//:/ })
    echo ${arrIN[1]}
  else
    echo ""
  fi
}
get_devportal_port() {
  local endpoint=$(docker port $GW_NAME 8003/tcp 2>/dev/null)
  if [ $? -eq 0 ];
  then
    local arrIN=(${endpoint//:/ })
    echo ${arrIN[1]}
  else
    echo ""
  fi
}
get_filesapi_port() {
  local endpoint=$(docker port $GW_NAME 8004/tcp 2>/dev/null)
  if [ $? -eq 0 ];
  then
    local arrIN=(${endpoint//:/ })
    echo ${arrIN[1]}
  else
    echo ""
  fi
}

# This function will process a -p argument request
# It's expected that the argument will look like
# hostport:containerport
# This will set the appropriate script level variable
# based on the argument
process_port_bind_request() {
  local request="${1}"
  IFS=':' read -ra KVP <<< "$request"
  if [[ ${#KVP[@]} -eq 2 ]];
  then
    local container_port_request="${KVP[1]}"
    if [[ $container_port_request -eq $DEFAULT_PROXY_PORT ]]; then
      PROXY_PORT="${KVP[0]}"
    elif [[ $container_port_request -eq $DEFAULT_ADMIN_PORT ]]; then
      ADMIN_PORT="${KVP[0]}"
    elif [[ $container_port_request -eq $DEFAULT_MANAGER_PORT ]]; then
      MANAGER_PORT="${KVP[0]}"
    elif [[ $container_port_request -eq $DEFAULT_DEVPORTAL_PORT ]]; then
      DEVPORTAL_PORT="${KVP[0]}"
    elif [[ $container_port_request -eq $DEFAULT_FILES_PORT ]]; then
      FILES_PORT="${KVP[0]}"
    else
      UNKNOWN_PORT_BIND_LIST+=(-p ${request})
    fi
  else
    echo_fail "Port bind request '${request}' is invalid"
    exit 1
  fi
}
process_volume_bind_request() {
  local request="${1}"
  VOLUMES+=(-v ${request})
}

# This function will process any user set env vars, and maybe
# set some local state for the script.
#
# The initial use case here is the user has provided KONG_PASSWORD
# and secured the admin API, preventing the installation of the
# mock service. So this will write a header w/ that password for curl
# to use.
#
# This function expects two arguments:
#   First the variable name, second the variable value
process_environment_variable() {
  local name="${1}"
  local value="${2}"

  if [ "${name}" = "KONG_PASSWORD" ]; then
    ADMIN_API_HEADERS+=('Kong-Admin-Token: '"${value}")
  fi

  if [ "${name}" = "KONG_DATABASE" ]; then
    local mode=$(echo "${value}" | tr '[:lower:]' '[:upper:]')
    if [ "${mode}" = "OFF" ]; then
      DB_LESS_MODE="true"
    fi
  fi
}

write_docker_run_env_file() {
  # TODO: To make the resulting env file nicer, we could search for overriden values
  #   in $ENVIRONMENT before writing these well known values to the file and not
  #   relying on the variables being overwritten
  echo "##############################################################################" >  $APP_NAME.env
  echo "# The following env file was used during docker run to set the container"       >> $APP_NAME.env
  echo "# environment for Kong Gateway"                                                 >> $APP_NAME.env
  echo "##############################################################################" >> $APP_NAME.env
  echo "KONG_DATABASE=postgres" >> $APP_NAME.env
  echo "KONG_PG_HOST=${DB_NAME}" >> $APP_NAME.env
  echo "KONG_PG_USER=${POSTGRES_USER}" >> $APP_NAME.env
  echo "KONG_PG_PASSWORD=${POSTGRES_PASSWORD}" >> $APP_NAME.env
  echo "KONG_ADMIN_LISTEN=0.0.0.0:8001, 0.0.0.0:8444 ssl" >> $APP_NAME.env
  echo "KONG_PROXY_ACCESS_LOG=/dev/stdout" >> $APP_NAME.env
  echo "KONG_ADMIN_ACCESS_LOG=/dev/stdout" >> $APP_NAME.env
  echo "KONG_PROXY_ERROR_LOG=/dev/stderr" >> $APP_NAME.env
  echo "KONG_ADMIN_ERROR_LOG=/dev/stderr" >> $APP_NAME.env

  if [ ${#ENVIRONMENT[@]} -gt 0 ]; then
    echo >> $APP_NAME.env
    echo "#############################################################################" >> $APP_NAME.env
    echo "# Environment overrides here that may supersede the values above" >> $APP_NAME.env
    echo "#############################################################################" >> $APP_NAME.env

    for item in "${ENVIRONMENT[@]}"
    do
      IFS='=' read -ra KVP <<< "$item"
      if [ "${#KVP[@]}" -gt "1" ];
      then
        echo "${item}" >> $APP_NAME.env
        process_environment_variable "${KVP[0]}" "${KVP[1]}"
      else
        local value=$(eval echo \$"${KVP[0]}")
        echo "${KVP[0]}=${value}" >> $APP_NAME.env
        process_environment_variable "${KVP[0]}" "${value}"
      fi
    done
  fi
}

write_env_file() {
  # TODO: may need to figure out how to pass these values to Docker without writing a local
  #   file first. Some may view this as less secure then a direct passthrough to the container environment

  echo "##############################################################################" > kong.env
  echo "# The following env file can be sourced and the variables used to " >> kong.env
  echo "# connect to Kong Gateway" >> kong.env
  echo "##############################################################################" >> kong.env
  echo >> kong.env
  echo "export KONG_PROXY=localhost:$(get_dataplane_port)" >> kong.env
  echo "export KONG_ADMIN_API=localhost:$(get_admin_port)" >> kong.env

  local manager_port=$(get_manager_port)
  [[ -z "$manager_port" ]] || echo "export KONG_MANAGER=localhost:$manager_port" >> kong.env

  local devportal_port=$(get_devportal_port)
  [[ -z "$devportal_port" ]] || echo "export KONG_DEV_PORTAL=localhost:$devportal_port" >> kong.env

  local files_port=$(get_filesapi_port)
  [[ -z "$files_port" ]] || echo "export KONG_FILES_API=localhost:$files_port" >> kong.env
}

install_mock_service() {
  echo ">install_mock_service" >> $LOG_FILE
  echo "Adding mock service at path /mock"

  ## First install the mock service under the admin api services route
  declare -a params=( --data name=mock --data url=http://mockbin.org )
  for h in "${ADMIN_API_HEADERS[@]}"
  do
    params+=( -H )
    params+=("${h}")
  done
  params+=("${1}/services")
  declare -i rv=$(curl_with_fail "${params[@]}")

  if [ $rv -eq 0 ]; then
    # then install the /mock route to point to the service on Kong Gateway
    params=( --data 'paths[]=/mock' --data name=mock )
    for h in "${ADMIN_API_HEADERS[@]}"
    do
      params+=( -H )
      params+=("${h}")
    done
    params+=("${1}/services/mock/routes")
    declare -i rv=$(curl_with_fail "${params[@]}")
  fi

  echo >> $LOG_FILE
  echo "<install_mock_service" >> $LOG_FILE
  return $rv
}

validate_kong() {
  echo ">validate_kong" >> $LOG_FILE
  local rv=0
  if curl -i $1 >> /dev/null 2>&1; then
    echo_pass "Kong Admin API is up"
  else
    #echo_fail "Issues connecting to Kong, check $LOG_FILE"
    rv=1
  fi
  echo "<validate_kong" >> $LOG_FILE
  return $rv
}

usage() {
  echo "Runs a Docker based Kong Gateway. The following documents the arguments and variables supported by the script."
  echo
  echo "Supported arguments:"
  echo "  -r Specify a different docker image registry (Default: $KONG_IMAGE_REPO)"
  echo "  -i Specify a different docker image name (Default: $KONG_IMAGE_NAME)"
  echo "  -t Specify a different docker image tag (Default: $DEFAULT_KONG_IMAGE_TAG)"
  echo "  -a Specify a different name for the quickstart application (Default: $APP_NAME)"
  echo "  -s Specify running Kong Gateway in secure mode."
  echo "      Admin API operations will need to use header 'Kong-Admin-Token: ${DEFAULT_KONG_PASSWORD}'. (Default: false)"
  echo "  -P Requests the usage of the available ports on the host machine instead of the Kong default ports (Default: false)"
  echo "      Docker will assign ports available on the host to each service"
  echo "  -p Explicitly bind a given host port to a Kong Gateway exposed port (multiple are allowed)."
  echo "      For example, to expose the Admin API port on host port 55202"
  echo "      -p 55202:8001"
  echo "  -e Pass environment variables to the Kong Gateway container"
  echo "      0-n number of -e arguments are permitted"
  echo "      To pass in a variable with a value in the current environment:"
  echo "        -e KONG_LICENSE_DATA"
  echo "      Or to pass an explicit value for a variable:"
  echo "        -e KONG_ENFORCE_RBAC=on"
  echo "  -v Bind mount a volume to the Kong Gateway container"
  echo "      0-n number of -v arguments are permitted"
  echo "  -m Installs a test service pointing to mockbin.org. A /mock route is added to utilize it. (Default: false)"
  echo "  -D Runs the quickstart in DB-Less mode and the database container is not started. (Default: false)"
  echo "  -h Shows this help"
  echo "  -d Destroys the current running instance. If you've changed the applicaiton name,"
  echo "    include the argument -a <appname>"
  echo
  echo "Examples:"
  echo
  echo "  * To Run Kong Gateway with a license, pass the license in via the KONG_LICENSE_DATA variable."
  echo "    Assuming you have the license data stored in KONG_LICENSE_DATA, pass the value in directly."
  echo "    If you're running the script directly on the command line, it would look like this:"
  echo "      ./quickstart -e KONG_LICENSE_DATA"
  echo "    If you're running the script by downloading via curl, it would look like this:"
  echo "      curl -Ls get.konghq.com/quickstart | bash -s -- -e KONG_LICENSE_DATA"
  echo
  echo "  * To run in licensed mode and enable RBAC, set KONG_LICENSE_DATA and KONG_ENFORCE_RBAC:"
  echo "      ./quickstart -e KONG_LICENSE_DATA -e KONG_ENFORCE_RBAC=on"
  echo
  echo "See the source repository for more information or to contact the developers:"
  echo "  https://github.com/Kong/get.konghq.com"
  exit 0
}

secure() {
  echo_warn "Secure mode enabled (requires Kong Gateway Enterprise to take effect)."
  ENVIRONMENT+=( KONG_PASSWORD=$DEFAULT_KONG_PASSWORD )
  ENVIRONMENT+=( KONG_AUDIT_LOG=on )
  ENVIRONMENT+=( KONG_LOG_LEVEL=debug )
  ENVIRONMENT+=( KONG_ENFORCE_RBAC=on )
  ENVIRONMENT+=( KONG_ADMIN_GUI_AUTH=basic-auth )
  ENVIRONMENT+=( KONG_ADMIN_GUI_SESSION_CONF='{"storage": "kong", "secret": "kongFTW", "cookie_name": "admin_session", "cookie_samesite":"off", "cookie_secure":false}' )
}

maybe_port_issue() {
  local re='^.*listen tcp4 [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:([0-9]{1,5}): bind: address already in use'
  local er=$(tail -n 2 $LOG_FILE)
  if [[ $er =~ $re ]]
  then
    echo_fail "Could not bind to port: ${BASH_REMATCH[1]}"
    echo
    echo_warn "Verify that the Kong default ports (8000-8004) are available on your host machine before trying again"
    echo_warn "You can also use the -p flag which will use available ports on the host machine"
  fi
}

destroy() {
  echo "Stopping and removing containers and networks:"
  docker rm -f $GW_NAME 2>/dev/null
  docker rm -f $DB_NAME 2>/dev/null
  docker network rm $APP_NAME-net 2>/dev/null
  echo_pass "Kong stopped"

  echo
  echo "Thanks for trying the Kong quickstart!"
  echo "The quickest way to get started in production is with Kong Konnect"
  echo
  echo " > https://get.konghq.com/konnect-free"
  echo
  exit 0
}

main() {
  local do_usage=false
  local do_destroy=false
  local securely=false

  while getopts "a:r:i:t:e:p:v:hdPsmD" o; do
    case "${o}" in
      r)
        KONG_IMAGE_REPO=${OPTARG}
        ;;
      i)
        KONG_IMAGE_NAME=${OPTARG}
        ;;
      t)
        KONG_IMAGE_TAG=${OPTARG}
        ;;
      e)
        ENVIRONMENT+=("${OPTARG}")
        ;;
      v)
        process_volume_bind_request ${OPTARG}
        ;;
      a)
        APP_NAME=${OPTARG}
        ;;
      h)
        do_usage=true
        ;;
      d)
        do_destroy=true
        ;;
      s)
        securely=true
        ;;
      p)
        process_port_bind_request ${OPTARG}
        ;;
      P)
        USE_DEFAULT_PORTS=false
        ;;
      D)
        DB_LESS_MODE=true
        ENVIRONMENT+=("KONG_DATABASE=off")
        ;;
      m)
        INSTALL_MOCK_SERVICE=true
        ;;
    esac
  done

  LOG_FILE="${LOG_FILE:-$APP_NAME.log}"
  DB_NAME="${APP_NAME}-database"
  GW_NAME="${APP_NAME}-gateway"

  echo ">main $@" >> $LOG_FILE

  if [ "$do_usage" = true ] ; then
    usage
  fi

  if [ "$do_destroy" = true ] ; then
    destroy
  fi

  echo "Prepare to Kong"
  echo "Debugging info logged to '$LOG_FILE'"

  # This is a helper for when a user has specified the well known
  # OSS image name 'kong', but hasn't overriden the image registry.
  # Then the script will help the user out by not specifying an image registry
  # because Kong OSS is pulled like: docker pull kong:2.8.1-ubuntu
  if [ "$KONG_IMAGE_REPO" = "$DEFAULT_KONG_IMAGE_REPO" ] && [ "$KONG_IMAGE_NAME" = "kong" ];
  then
    KONG_IMAGE_REPO=""
  fi

  if [ -z "$KONG_IMAGE_REPO" ]
  then
    KONG_IMAGE="${KONG_IMAGE_NAME}:${KONG_IMAGE_TAG}"
  else
    KONG_IMAGE="${KONG_IMAGE_REPO}/${KONG_IMAGE_NAME}:${KONG_IMAGE_TAG}"
  fi

  ensure_docker || {
    echo_fail "Docker is not available, check $LOG_FILE"; exit 1
  }

  docker_pull_images || {
    echo_fail "Download failed, check $LOG_FILE"; exit 1
  }

  destroy_kong

  if [ "$securely" = true ] ; then
    secure
  fi

  write_docker_run_env_file

  init || {
    echo_fail "Initalization steps failed, check $LOG_FILE"; exit 1
  }

  if [ "$DB_LESS_MODE" != "true" ];
  then
    db || {
      echo_fail "DB initialization failed, check $LOG_FILE"; exit 1
    }
  fi

  kong || {
    echo_fail "Kong initialization failed, check $LOG_FILE";
    maybe_port_issue
    exit 1
  }

  DATA_PLANE_ENDPOINT=localhost:$(get_dataplane_port)
  CTRL_PLANE_ENDPOINT=localhost:$(get_admin_port)

  validate_kong $CTRL_PLANE_ENDPOINT || {
    echo_fail "Validation failed, could not connect to Kong. Check $LOG_FILE"; exit 1
  }

  if [ "$INSTALL_MOCK_SERVICE" = true ] ; then
    install_mock_service $CTRL_PLANE_ENDPOINT && {
      echo_pass "mock service installed. /mock -> mockbin.org"
    } || {
      echo_fail "Installing mock service failed, check $LOG_FILE"; exit 1
    }
  fi

  write_env_file

  echo_pass "Kong is ready!"

  echo
  echo "======================="
  echo " ⚒️ Environment Created"
  echo "======================="
  echo
  echo "To stop the gateway and database, run:"
  echo
  echo "    curl https://get.konghq.com/quickstart | bash -s -- -d -a $APP_NAME"
  echo

  echo "Kong Data Plane endpoint = $DATA_PLANE_ENDPOINT"
  echo "Kong Admin API endpoint  = $CTRL_PLANE_ENDPOINT"
  echo
  echo "This script has written an environment file you can source to make connecting to Kong easier."
  echo "Run this command to source these variables into your environment:"
  echo
  echo "    source kong.env"
  echo
  echo "Now you can interact with your new Kong Gateway using these variables, for example:"
  echo
  echo '    curl -s $KONG_PROXY/mock/requests'


  echo
  echo "======================="
  echo " 🐵 Using Kong"
  echo "======================="

  echo
  echo "To administer the gateway, use the Admin API:"
  echo

  printf "    curl"
  for h in "${ADMIN_API_HEADERS[@]}"
  do
    printf " -H "
    printf "'%s'" "$h"
  done
  printf " -s http://$CTRL_PLANE_ENDPOINT\n"

  if [[ $KONG_IMAGE_NAME == "kong-gateway" ]]; then
    local manager_port=$(get_manager_port)
    echo
    echo "We recommend using Kong Manager UI to help visualize your configuration"
    echo "as you work through the quickstart"
    echo
    echo "    Open in your browser: http://localhost:$manager_port"
    echo
  fi

  echo "<main" >> $LOG_FILE
}

main "$@"
