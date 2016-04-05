_smash_zstyle=":smart-ssh"

_smash_get_option() {
    local name="$1"
    local default_value="${2:-}"

    local value
    if zstyle -g value "$_smash_zstyle" "$name"; then
        echo "$value";
    else
        echo "$default_value"
    fi
}

_smash_get_zone_regexp() {
    local pattern=$(IFS="|" && echo "${whitelist_zone[*]}")
    pattern=$(sed 's/\./\\./g' <<< "$group")
    echo "($group)$"
}


_smash_get_full_hostname() {
    local hostname="$1"
    local dns_response=$(dig +search +short -t cname "$hostname")
    [ -n "$dns_response" ] \
        && echo "${dns_response%.}" \
        || echo "$hostname"
}

_smash_get_counter() {
    local hostname="$1"

    local dir=$(_smash_get_option counters ~/.ssh/counters/)
    /bin/mkdir -p "$dir"

    local file="$dir/$hostname"
    touch "$file"

    local counter=$(cat "$file")
    echo "${counter:-0}"
}

_smash_set_counter() {
    local hostname="$1"
    local value="$2"

    local dir=$(_smash_get_option counters ~/.ssh/counters/)

    echo -n "$value" >! "$dir/$hostname"
}

_smash_remove_counter() {
    local hostname="$1"

    local dir=$(_smash_get_option counters ~/.ssh/counters/)

    /bin/rm -f "$dir/$hostname"
}

_smash_is_synced_hostname() {
    local hostname="$1"

    local dir=$(_smash_get_option syncs ~/.ssh/syncs/)
    /bin/mkdir -p "$dir"

    [ -f "$dir/$hostname" ]
    return $?
}

_smash_set_synced() {
    local hostname="$1"

    local dir=$(_smash_get_option syncs ~/.ssh/syncs/)
    /bin/mkdir -p "$dir"

    touch "$dir/$hostname"
}

_smash_is_in_whitelist() {
    local hostname="$1"
    local whitelist=$(_smash_get_option whitelist)
    if [ -n "$whitelist" ]; then
        /bin/grep -q -E \
            "$(_smash_get_zone_regexp "$whitelist")" <<< "$hostname"
        return $?
    fi

    return 1
}

_smash_get_username() {
    _smash_get_option username $(whoami)
}

_smash_get_auth_count() {
    _smash_get_option auth-count 3
}

_smash_get_ssh_options() {
    local variable="$1"
    zstyle -a $_smash_zstyle ssh-options $variable
    if [ $? -ne 0 ]; then
        $variable=("-t")
    fi
}


_smash_copy_id() {
    local username="$1"
    local hostname="$2"
    local output

    output=$(ssh-copy-id \
            -o "PubkeyAuthentication=no" -o "ControlMaster=no" \
            "$username@$hostname" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$output"
        return 1
    fi
}


_smash_ssh() {
    local username="$1"
    local hostname="$2"
    local cmd="$3"

    local options
    _smash_get_ssh_options options

    if [ -n "$cmd" ]; then
        options+=("$cmd")
    fi

    ssh "$hostname" -l "$username" ${options[@]}
    return $?
}

smart-ssh() {
    [ $# -gt 0 ] || return 1

    local hostname=$(_smash_get_full_hostname "$1")
    shift
    local cmd="$@"

    local username=$(_smash_get_username)

    local should_sync=false
    if ! _smash_is_synced_hostname "$hostname"; then
        if _smash_is_in_whitelist "$hostname"; then
            should_sync=true
        else
            local counter=$(_smash_get_counter "$hostname")
            counter=$((counter+1))
            if [ $counter -ge $(_smash_get_auth_count) ]; then
                should_sync=true
            fi
            _smash_set_counter "$hostname" $counter
        fi
    fi


    if $should_sync; then
        if _smash_copy_id "$username" "$hostname"; then
            _smash_remove_counter "$hostname"
            _smash_set_synced "$hostname"
        fi
    fi

    _smash_ssh "$username" "$hostname" "$cmd"
    return $?
}

compdef smart-ssh=ssh
