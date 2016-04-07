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
    local username="$1"
    local hostname="$2"
    local identity="$3"
    local output

    output=$(ssh-copy-id \
            ${identity:+-i${identity}} \
            -o "PubkeyAuthentication=no" -o "ControlMaster=no" \
            "$username@$hostname" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$output"
        return 1
    fi
}

_smash_parse_commmand_line() {
    # for ## pattern in case
    setopt local_options extended_glob

    # from man ssh
    local opts_without_arg="1246AaCfGgKkMNnqsTtVvXxYy"
    local opts_with_arg="bcDEeFIiLlmOopQRSWw"

    local opts=()
    local positionals=()

    local username=""
    local identity=""

    # parse ssh options and split flags from positional arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            # zsh '##' == regexp '+'
            -[$opts_without_arg]##)
                opts+=$1
                ;;

            -l)
                username=$2
                shift
                ;;

            -l*)
                username=${1#-l}
                ;;

            -i)
                identity=$2
                opts+=$1$2
                shift
                ;;

            -i*)
                identity=${1#-i}
                opts+=$1
                ;;

            -[$opts_with_arg])
                opts+=$1$2
                shift
                ;;

            -[$opts_with_arg]*)
                opts+=$1
                ;;

            -*)
                echo unknown ssh flag: "$1"
                return 1
                ;;

            *@*)
                username=${1%@*}
                positionals+=${1#*@}
                ;;

            *)
                positionals+=$1
                ;;
        esac

        shift

        if [ ${#positionals} -ge 2 ]; then
            break
        fi
    done

    if [ $# -gt 0 ]; then
        positionals+=($@)
    fi

    export _ssh_username=$username
    export _ssh_identity=$identity
    export _ssh_hostname=${positionals:0:1}
    export _ssh_opts=$(_smash_serialize_array "${opts[@]}")
    export _ssh_command=$(_smash_serialize_array ${positionals:1})
}

_smash_serialize_array() {
    echo -E ${(qqq)@}
}

smart-ssh() {
    _smash_parse_commmand_line "${@}"

    local opts=$_ssh_opts
    local username=$_ssh_username
    local identity=$_ssh_identity
    local hostname=$_ssh_hostname
    local command=$_ssh_command

    if [ $? -gt 0 ]; then
        exit $?
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
        if _smash_copy_id "$username" "$full_hostname" "$identity"; then
            _smash_remove_counter "$full_hostname"
            _smash_set_synced "$full_hostname"
        fi
    fi

    # (z) will split serialized options using shell syntax, but not remove
    #     quotes
    # (Q) will remove leftover quotes
    ssh ${(Q)${(z)opts}} ${username:+-l${username}} "$hostname" \
        ${command:+"${(Q)command}"} # will pass command only if it's not empty

    return $?
}
