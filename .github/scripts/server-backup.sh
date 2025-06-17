#!/bin/bash

# ==============================================================================
# ================= Execute these functions on SERVER ==========================
# =============================================================================

main() {
    populate_variables "$@"
    check_required_files
    check_and_install_dependencies
    backup_file_path=$(create_backup_inside_container)
    copy_backup_to_host $backup_file_path
    delete_old_backup_files_inside_container
}

populate_variables() {
    declare -g docker_compose_path="/opt/odoo" # path to folder contains docker-compose.yml file - on host machine
    declare -g db_name="odoo"             # supplied by jenkins pipeline - config manually in pipeline
    declare -g db_password="odoo"
    declare -g odoo_image_tag="latest" # odoo image tag - declared in docker compose file

    # this number will greater than 1 for re-run jobs, this happend when a job failed
    # the reason: a job failed because we are testing on an older db, so we should get the latest db when retry testing
    # there are many other reason but we will cover it later
    declare -g job_attempt_number=1
    declare -g host_backup_folder="/tmp/odoo/backup/bep/main" # the backup folder path on the host
    declare -g docker_backup_folder=/tmp/odoo-backup # the backup folder path inside the Odoo container
    declare -g config_file=/etc/odoo/odoo.conf  # path inside the Odoo container

    declare -g db_host=$(get_config_value "db_host")
    declare -g db_host=${db_host:-'db'}
    declare -g db_port=$(get_config_value "db_port")
    declare -g db_port=${db_port:-'5432'}
    declare -g db_user=$(get_config_value "db_user")
    declare -g db_user=${db_user:-'odoo'}

    declare -g data_dir=$(get_config_value "data_dir")
    declare -g data_dir=${data_dir:-'/var/lib/odoo'}
    declare -g DATE_FORMAT="%Y-%m-%d_%H-%M-%S"
}

check_required_files() {
    if [[ ! -d $docker_compose_path ]]; then
        echo "Docker compose path '$docker_compose_path' does not exist on host machine"
        exit 1
    fi

    execute_command_inside_odoo_container "[ ! -f $config_file ]"
    if [[ $? == 0 ]]; then
        echo "Config file in '$config_file' path does not exist on Odoo container"
        exit 1
    fi
}

get_config_value() {
    param=$1
    execute_command_inside_odoo_container "grep -q -E \"^\s*\b${param}\b\s*=\" \"$config_file\""
    if [[ $? == 0 ]]; then
        value=$(execute_command_inside_odoo_container "grep -E \"^\s*\b${param}\b\s*=\" \"$config_file\" | cut -d \" \" -f3 | sed 's/[\"\n\r]//g'")
    fi
    echo "$value"
}

get_odoo_container_id() {
    cd $docker_compose_path
    image_tag=$1
    docker ps -q --filter "name=odoo-app" | head -n 1
}

execute_command_inside_odoo_container() {
    odoo_container_id=$(get_odoo_container_id $odoo_image_tag)
    if [[ -z $odoo_container_id ]]; then
        echo "There is no running Odoo container with tag name '$odoo_image_tag'"
        exit 1
    fi
    docker exec $odoo_container_id sh -c "$@"
}

should_we_generate_new_backup() {
    if [[ $job_attempt_number -gt 1 ]]; then
        echo "true"
        return 0
    fi
    echo "false"
    # latest_backup_file_creation_timestamp=$1
    # current_timestamp=$(execute_command_inside_odoo_container "date -u +%s")
    # different=$((current_timestamp - latest_backup_file_creation_timestamp))
    # # todo: set the time to environment variable so we can config differently for each project
    # # we should get a new backup file when the latest backup file is older than 1 hour
    # if [[ $different -gt '3600' ]]; then
    #     echo "true"
    # else
    #     echo "false"
    # fi
}

convert_datetime_string_to_timestamp() {
    date_string=$1 # in format : $DATE_FORMAT
    valid_date_string=$(echo $date_string | sed "s/-/\//; s/-/\//; s/_/ /; s/-/:/; s/-/:/")
    echo $(date -u -d "$valid_date_string" "+%s")
}

create_backup_inside_container() {
    # Create sql and filestore backup inside the Odoo container
    # backup folder will contain *.zip files
    # The .zip file contains:
    #   - dump.sql : Oodo database dump file
    #   - filestore: Odoo filestore folder
    latest_backup_zip_file=$(get_latest_backup_zip_file_inside_container)
    latest_backup_zip_file_path="$docker_backup_folder/$latest_backup_zip_file"
    create_new_backup="false"
    if [ -n "$latest_backup_zip_file" ]; then
        creation_date=$(echo $latest_backup_zip_file | sed "s/^${db_name}_//; s/\.zip//")
        timestamp=$(convert_datetime_string_to_timestamp "$creation_date")
        create_new_backup=$(should_we_generate_new_backup $timestamp)
    else
        create_new_backup="true"
    fi

    if [[ $create_new_backup == "true" ]]; then
        sub_backup_folder=$(create_sub_backup_folder_inside_container)
        create_sql_backup $sub_backup_folder
        create_filestore_backup $sub_backup_folder
        new_backup_zip_file_path=$(create_zip_file_backup $sub_backup_folder)
        echo $new_backup_zip_file_path
    else
        echo $latest_backup_zip_file_path
    fi
}

copy_backup_to_host() {
    backup_file_path=$1
    odoo_container_id=$(get_odoo_container_id $odoo_image_tag)
    
    # Tạo thư mục backup trên host nếu chưa tồn tại
    [ ! -d "$host_backup_folder" ] && mkdir -p "$host_backup_folder"
    
    # Kiểm tra xem file có tồn tại trong container không
    if ! execute_command_inside_odoo_container "[ -f \"$backup_file_path\" ]"; then
        echo "Error: Backup file $backup_file_path does not exist in container"
        exit 1
    fi
    
    # Sao chép file từ container ra host
    docker cp $odoo_container_id:$backup_file_path $host_backup_folder
    
    # Kiểm tra xem file đã được sao chép thành công chưa
    latest_backup_file_name=$(basename $backup_file_path)
    if [ ! -f "$host_backup_folder/$latest_backup_file_name" ]; then
        echo "Error: Failed to copy backup file to host"
        exit 1
    fi
    
    echo "$host_backup_folder/$latest_backup_file_name"
}

get_latest_backup_zip_file_inside_container() {
    execute_command_inside_odoo_container "[ ! -d \"$docker_backup_folder\" ] && mkdir -p \"$docker_backup_folder\""
    latest_backup_zip_file=$(execute_command_inside_odoo_container "ls -tr \"$docker_backup_folder\" | tail -n 1 | grep -E \"^${db_name}_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip$\"")
    echo ${latest_backup_zip_file}
}

create_sub_backup_folder_inside_container() {
    folder_name=$(execute_command_inside_odoo_container "echo $docker_backup_folder/${db_name}_$(date -u +$DATE_FORMAT)")
    execute_command_inside_odoo_container "mkdir -p \"$folder_name\""
    echo $folder_name
}

create_sql_backup() {
    sub_backup_folder=$1
    sql_file_path="${sub_backup_folder}/dump.sql"
    pgpass_path="~/.pgpass"
    execute_command_inside_odoo_container "touch $pgpass_path ; echo $db_host:$db_port:\"$db_name\":$db_user:$db_password > $pgpass_path ; chmod 0600 $pgpass_path"
    execute_command_inside_odoo_container "pg_dump -h \"$db_host\" -U $db_user --no-owner --file \"$sql_file_path\" \"$db_name\""
}

create_filestore_backup() {
    sub_backup_folder=$1
    file_store_path="$data_dir/filestore/$db_name"
    
    # Kiểm tra thư mục filestore có tồn tại không
    if ! execute_command_inside_odoo_container "[ -d \"$file_store_path\" ]"; then
        echo "Warning: Filestore directory $file_store_path does not exist, creating empty directory"
        execute_command_inside_odoo_container "mkdir -p \"$sub_backup_folder/filestore\""
        return 0
    fi
    
    # Sao chép filestore
    execute_command_inside_odoo_container "cp -r \"$file_store_path\" \"$sub_backup_folder/filestore\""
}

create_zip_file_backup() {
    sub_backup_folder=$1
    sub_backup_folder_name=$(basename $sub_backup_folder)
    new_backup_zip_file_path="${sub_backup_folder_name}.zip"
    
    # Cài đặt zip nếu chưa có
    execute_command_inside_odoo_container "which zip >/dev/null 2>&1 || (apt-get update && apt-get install -y zip)"
    
    # Tạo file zip
    execute_command_inside_odoo_container "cd \"$sub_backup_folder\" && zip -rq \"../${new_backup_zip_file_path}\" . && rm -rf \"$sub_backup_folder_name\""
    echo "${docker_backup_folder}/${new_backup_zip_file_path}"
}

delete_old_backup_files_inside_container() {
    # remove all temporary backup file inside container
    execute_command_inside_odoo_container "cd $docker_backup_folder && rm -rf *"
}

# Thêm hàm mới để kiểm tra và cài đặt các dependencies
check_and_install_dependencies() {
    # Kiểm tra và cài đặt zip
    execute_command_inside_odoo_container "which zip >/dev/null 2>&1 || (apt-get update && apt-get install -y zip)"
    
    # Kiểm tra và cài đặt pg_dump
    execute_command_inside_odoo_container "which pg_dump >/dev/null 2>&1 || (apt-get update && apt-get install -y postgresql-client)"
}

main "$@"
