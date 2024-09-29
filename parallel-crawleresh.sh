#!/bin/bash

source "$(which env_parallel.bash)"

# Default values
SSH_CONNECTION_STRING=""
url_list=""
PROJECT_NAME=""
no_hosts=0
server_args=""

# Function to display help
show_help() {
    echo "Usage: $0 -r <return_host> -f <url_list_file> -n <project_name> -w <worker_host> [-w <worker_host>]..."
    echo ""
    echo "Arguments:"
    echo "  -r <return_host>   The SSH connection string of the return host (username@IP:port)."
    echo "  -f <url_list_file> The file containing a list of URLs to be processed."
    echo "  -n <project_name>  The name of the project."
    echo "  -w <worker_host>   Specify a worker host in the format username@IP:port."
    echo "                      At least one -w option is required."
    echo "  -h                 Show this help message."
    echo ""
    echo "Example:"
    echo "  $0 -r userName@10.7.0.6:22 -f https___shopify.dev.csv -n MyProject -w 190.60.50.60:80 -w 127.0.0.1"
    echo ""
    echo "This script performs parallel downloading of URLs from the specified list across multiple servers (worker_hosts)."
    echo "It works with SSH and rsync, so the port specified must be the one SSH is served on each host (omit to use the default one 22)."
    echo "You must specify at least one worker host with the -w option."
    echo "Note: By default, localhost will not be used as a worker host; if desired, specify it with -w 127.0.0.1."
    echo ""
    echo "- First Time Installation"
    echo "To prepare the system for these scripts you need to add 2 environment variables on each worker_host:"
    echo ""
    echo "$ sudo vi /home/myuser/.bashrc"
    echo "export MAIN_DISK=/dev/sda"
    echo "export DOWN_PATH=/home/myuser/downloads"
    echo ""
    echo "$ vi /home/myuser/.ssh/environment"
    echo "MAIN_DISK=/dev/sda"
    echo "DOWN_PATH=/home/myuser/downloads"
    echo ""
    echo "Changing the following Directive:"
    echo "$ sudo vi /etc/ssh/sshd_config"
    echo "PermitUserEnvironment yes"
}

# Parsing the options with getopts
while getopts "r:f:n:w:h" opt; do
    case $opt in
        r)  # Return host
            SSH_CONNECTION_STRING=${OPTARG}
            ;;
        f)  # URL list file
            url_list=${OPTARG}
            ;;
        n)  # Project name
            PROJECT_NAME=${OPTARG}
            ;;
        w)  # Server username@IP:port
            server_args+="-w ${OPTARG} "
            ((no_hosts++))
            ;;
        h)  # Show help
            show_help
            exit 0
            ;;
        *)  # Invalid option
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
    esac
done

# Ensure required options are provided
if [[ -z "${SSH_CONNECTION_STRING}" || -z "${url_list}" || -z "${PROJECT_NAME}" ]]; then
    echo "Error: -r (return host), -f (url list file), and -n (project name) are required."
    show_help
    exit 1
fi

# Ensure at least one -w (worker_host) option is provided
if [[ ${no_hosts} -eq 0 ]]; then
    echo "Error: At least one -w (worker_host username@IP:port) is required."
    show_help
    exit 1
fi

# Extract the base name and extension separately
base_name="${url_list%.*}"  # Get the file name without the extension
extension="${url_list##*.}" # Get the extension
changes_file="${base_name}-ch.${extension}"


main() {
## MAIN INDEXING PROCESS
#    echo 'something' | env_parallel -n0 \
	env_parallel \
        `## GLOBAL SCRIPT VARIABLES` \
        --env SSH_CONNECTION_STRING \
        --env MASTER_PATH \
        --env MASTER_HOSTNAME \
        --env PROJECT_NAME \
        `## FUNCTIONS TO BE EXECUTED` \
        --env down_and_pull \
        --env check_disk_space\
        --env pull_chunk \
        ${server_args} \
		-a ${url_list} \
        down_and_pull | tee -a "${changes_file}"

## PULLING LAST CHUNKS
## Need to throw one time per host
for (( i=0 ; i < no_hosts ; i++ )); do
    printf " \n" | env_parallel \
         -n0 \
        `## GLOBAL SCRIPT VARIABLES` \
        --env SSH_CONNECTION_STRING \
        --env MASTER_PATH \
        --env MASTER_HOSTNAME \
        --env PROJECT_NAME \
        `## FUNCTIONS TO BE EXECUTED` \
        --env pull_chunk \
        --env pull_last_chunk \
        ${server_args} \
        pull_last_chunk
done


update_csv ${url_list} ${changes_file}
rm ${changes_file}
exit 0
}


### Function to handle interrupts (Ctrl+C)
##handle_interrupt() {
##    echo -e "\nInterrupt received! Updating CSV before exit..."
##    update_csv ${url_list} ${changes_file}
##    exit 0
##}

### Set trap to catch SIGINT (Ctrl + C)
##trap handle_interrupt SIGINT


update_csv(){
## Given an original_file .csv with two columns
##    And a changes_file
##              - Same first column fields
##              - Different second columnd fields
##              - Rows may be disordered
##  Update the original file keeping the order of rows
##      It will update by creating a buffer_file
##         This is made in mind for large files modification
##            Should the process get interrupted 
##                buffer_file will be there


    original_file=${1}
    changes_file=${2}
    echo  "Updating ${original_file} with ${changes_file} ..." >&2

    # Extract the base name and extension separately
    base_name="${original_file%.*}"  # Get the file name without the extension
    extension="${original_file##*.}" # Get the extension

    buffer_file="${base_name}-buf.${extension}"


    ## Checking on changes_file , creating an associative array
    declare -A changes_file_col2
    while IFS=',' read -r col_1 col_2 ; do
        changes_file_col2["$col_1"]="${col_2}"
    done < ${changes_file}

    ## If buffer_file already exist, check the line_no it has left it of
    ## wc -l is base 1 count
    start_line=1
    if [[ -f ${buffer_file} ]]; then
        start_line=$(wc -l < "${buffer_file}")
    fi

    counter=0
    # Iterate over original_file and update the status
    while IFS=',' read -r col_1 col_2 ; do
        if (( counter < start_line )); then
            ((counter++))
            continue  # Skip rows before the start line
        fi

        if [[ -n "${changes_file_col2[$col_1]}" ]]; then
            # Replace col2 with the one from changes_file
            col_2="${changes_file_col2[$col_1]}"
        fi
        echo "${col_1},${col_2}" >> ${buffer_file}
        ((counter++))
    done < ${original_file}

    ## If process finnish, replace original_file 
    mv ${buffer_file} ${original_file}

}


check_disk_space() {
    MASTER_USER=${1}
    MASTER_IP=${2}
    MASTER_PORT=${3}
    MASTER_PATH=${4}
	WORKER_PATH=${5}
	WORKER_DISK=${6}
    PROJECT_NAME=${7}

    if [ $(df | awk -v disk="${WORKER_DISK}" '$1 == disk {print $4}') -gt 512000 ]; then
        :
    else
       pull_chunk ${MASTER_USER} ${MASTER_IP} ${MASTER_PORT} ${MASTER_PATH} ${WORKER_PATH} ${WORKER_DISK} ${PROJECT_NAME}

    fi
}
export -f check_disk_space




pull_last_chunk() {

## COLLECTING GLOBAL VARIABLES
MASTER_CONNECTION_STRING=${SSH_CONNECTION_STRING}


## COLLECTING LOCAL VARIABLES
WORKER_PATH=${DOWN_PATH}
WORKER_DISK=${MAIN_DISK}

## PROCESSING VARIABLES
# Extracting the username, IP, and port
MASTER_USER="${MASTER_CONNECTION_STRING%%@*}" 
MASTER_HOST_PART="${MASTER_CONNECTION_STRING#*@}"
MASTER_IP="${MASTER_HOST_PART%%:*}"
MASTER_PORT="${MASTER_HOST_PART##*:}"



echo "PROJECT_NAME : ${PROJECT_NAME}" >&2
echo "WORKER_PATH : ${WORKER_PATH}" >&2
echo "WORKER_DISK : ${WORKER_DISK}" >&2
echo "MASTER_USER : ${MASTER_USER}" >&2
echo "MASTER_IP : ${MASTER_IP}" >&2
echo "MASTER_PORT : ${MASTER_PORT}" >&2
echo "PROJECT_NAME : ${PROJECT_NAME}" >&2
echo "MASTER_HOSTNAME : ${MASTER_HOSTNAME}" >&2
echo "HOSTNAME : ${HOSTNAME}" >&2


    if [[ ${HOSTNAME} != ${MASTER_HOSTNAME} ]]; then
       echo "Pulling Last Chunk from ${HOSTNAME} to ${MASTER_IP}" >&2
       pull_chunk ${MASTER_USER} ${MASTER_IP} ${MASTER_PORT} ${MASTER_PATH} ${WORKER_PATH} ${WORKER_DISK} ${PROJECT_NAME}
    fi

}
export -f pull_last_chunk


pull_chunk() {
    MASTER_USER=${1}
    MASTER_IP=${2}
    MASTER_PORT=${3}
    MASTER_PATH=${4}
	WORKER_PATH=${5}
	WORKER_DISK=${6}
    PROJECT_NAME=${7}

        echo "Pulling Chunk from ${HOSTNAME} to ${MASTER_IP}" >&2

        rsync -av -e "ssh -p ${MASTER_PORT}" --remove-source-files "${DOWN_PATH}/${PROJECT_NAME}/" ${MASTER_USER}@${MASTER_IP}:"${MASTER_PATH}/${PROJECT_NAME}/" 1>&2
}
export -f pull_chunk


down_and_pull(){

## COLLECTING GLOBAL VARIABLES
MASTER_CONNECTION_STRING=${SSH_CONNECTION_STRING}


## COLLECTING LOCAL VARIABLES
WORKER_PATH=${DOWN_PATH}
WORKER_DISK=${MAIN_DISK}

## PROCESSING VARIABLES
# Extracting the username, IP, and port
MASTER_USER="${MASTER_CONNECTION_STRING%%@*}" 
MASTER_HOST_PART="${MASTER_CONNECTION_STRING#*@}"
MASTER_IP="${MASTER_HOST_PART%%:*}"
MASTER_PORT="${MASTER_HOST_PART##*:}"


    row=$1

    ## Skip the header
    [ "${row}" == "url,exit_status" ] && return
##    [ "${row}" == "url,exit_status" ] && echo "url,exit_status" && return
     
    ##  grab de exit status
    exit_status=$(echo "$row" | cut -d',' -f2)

    if [[ ${exit_status} == -1  ]]; then

        url=$(echo "$row" | cut -d',' -f1)

        dirpath=$(echo "$url" | sed 's|https://||;s|/[^/]*$||')
        filename=$(basename "$url")

        ## If current hostname is not the same as invoking hostname, then transfer bits
        if [[ ${HOSTNAME} != ${MASTER_HOSTNAME} ]]; then
            check_disk_space ${MASTER_USER} ${MASTER_IP} ${MASTER_PORT} ${MASTER_PATH} ${WORKER_PATH} ${WORKER_DISK} ${PROJECT_NAME}
        fi

        [ ! -d "${WORKER_PATH}/${PROJECT_NAME}/${dirpath}" ] && mkdir -p "${WORKER_PATH}/${PROJECT_NAME}/${dirpath}"
        wget -nc --adjust-extension --directory-prefix=${WORKER_PATH}/${PROJECT_NAME}/${dirpath} ${url} > /dev/null 2>&1
        wget_status=${?}
        row="${url},${wget_status}"
        echo ${row}


    fi
}
export -f down_and_pull

main
