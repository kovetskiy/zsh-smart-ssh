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
    local pattern=${(j:|:)whitelist_zone}
    local group=${pattern//./\\.}
    echo "($group)$"
}


_smash_get_full_hostname() {
    local hostname="$1"
    local dns_response=$(dig +search +short -t cname "$hostname")
    echo "${${dns_response%.}:-$hostname}"
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

_smash_get_auth_count() {
    _smash_get_option auth-count 3
}

_smash_copy_id() {
    local login="$1"
    local hostname="$2"
    local identity="$3"
    local output

    output=$(ssh-copy-id \
            ${identity:+-i${identity}} \
            -o "PubkeyAuthentication=no" -o "ControlMaster=no" \
            "${login:+${login}@}$hostname" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$output"
        return 1
    fi
}

smart-ssh() {
    local login
    local hostname
    local identity
    local interactive
    local opts

    # workaround for parsing cases like ssh -X hostname -t command
    while [ ! "$hostname" ]; do
        zparseopts -a opts -D \
            'b:' 'c:' 'D:' 'E:' 'e:' 'F:' 'I:' 'L:' 'm:' 'O:' 'o:' \
            'p:' 'Q:' 'R:' 'S:' 'W:' 'w:' \
            'l:=login' \
            'i:=identity' \
            '1' '2' '4' '6' 'A' 'a' 'C' 'f' 'G' 'g' 'K' 'k' 'M' 'N' 'n' 'q' \
            's' 'T' 'V' 'v' 'X' 'x' 'Y' 'y' \
            't=interactive'

        hostname="$1"
        if [ ! "$hostname" ]; then
            echo smart-ssh: hostname is not specified
            exec ssh -h
        fi

        shift
    done

    opts+=($interactive $login $identity)

    if [ "${hostname%@*}" != "$hostname" ]; then
        opts+=(-l${hostname%@*})
        login=${hostname%@*}
        hostname=${hostname#*@}
    fi

    local full_hostname=$(_smash_get_full_hostname "$hostname")

    local should_sync=false
    if ! _smash_is_synced_hostname "$full_hostname"; then
        if _smash_is_in_whitelist "$full_hostname"; then
            should_sync=true
        else
            local counter=$(_smash_get_counter "$full_hostname")
            counter=$((counter+1))
            if [ $counter -ge $(_smash_get_auth_count) ]; then
                should_sync=true
            fi

            _smash_set_counter "$full_hostname" $counter
        fi
    fi


    if $should_sync; then
        if _smash_copy_id "$login" "$full_hostname" "$identity"; then
            _smash_remove_counter "$full_hostname"
            _smash_set_synced "$full_hostname"
        fi
    fi

    ssh "${opts[@]}" "$full_hostname" ${@}
}
