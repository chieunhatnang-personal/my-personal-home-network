#!/usr/bin/env bash

set -euo pipefail

APP_NAME="multi_git"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${APP_NAME}"
ACCOUNTS_FILE="${CONFIG_DIR}/accounts.tsv"
REPOS_FILE="${CONFIG_DIR}/repos.tsv"
SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

usage() {
    cat <<'EOF'
multi_git.sh - interactive helper for multiple Git/GitHub accounts

Usage:
  ./multi_git.sh help
  ./multi_git.sh add acc [alias]
  ./multi_git.sh del acc [alias]
  ./multi_git.sh list acc
  ./multi_git.sh add repo [alias] [owner/repo-or-url]
  ./multi_git.sh del repo
  ./multi_git.sh list repo

What it does:
  add acc   Generate or reuse an SSH key, add an SSH host alias, and save
            local-only Git identity metadata under ~/.config/multi_git.
  add repo  Configure the current Git repo or clone a repo using one of the
            saved account aliases, then set local user.name/user.email.
  del acc   Remove a saved account and its managed SSH config block.
  del repo  Remove origin from the current repo and optionally unset identity.

Notes:
  - This script intentionally contains no personal account data.
  - Account details are stored only on the machine running the script.
  - Saved repo choices are stored only on the machine running the script.
  - SSH config blocks are marked with "multi_git account" comments.
EOF
}

ensure_config() {
    mkdir -p "$CONFIG_DIR" "$SSH_DIR"
    chmod 700 "$CONFIG_DIR" "$SSH_DIR" 2>/dev/null || true

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        {
            printf '# alias\thost_alias\thost_name\tkey_path\tuser_name\tuser_email\n'
        } >"$ACCOUNTS_FILE"
    fi

    if [[ ! -f "$REPOS_FILE" ]]; then
        {
            printf '# alias\trepo_path\n'
        } >"$REPOS_FILE"
    fi

    if [[ ! -f "$SSH_CONFIG" ]]; then
        : >"$SSH_CONFIG"
    fi

    chmod 600 "$ACCOUNTS_FILE" "$REPOS_FILE" "$SSH_CONFIG" 2>/dev/null || true
}

prompt() {
    local label="$1"
    local value
    printf '%s: ' "$label" >&2
    IFS= read -r value
    printf '%s' "$value"
}

prompt_default() {
    local label="$1"
    local default_value="$2"
    local value
    printf '%s [%s]: ' "$label" "$default_value" >&2
    IFS= read -r value
    printf '%s' "${value:-$default_value}"
}

prompt_required() {
    local label="$1"
    local value

    while true; do
        value="$(prompt "$label")"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return
        fi
        info "Value is required."
    done
}

confirm() {
    local label="$1"
    local default_value="${2:-no}"
    local suffix answer

    case "$default_value" in
        yes) suffix='[Y/n]' ;;
        no) suffix='[y/N]' ;;
        *) die "confirm default must be yes or no" ;;
    esac

    while true; do
        printf '%s %s ' "$label" "$suffix" >&2
        IFS= read -r answer
        answer="${answer:-$default_value}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) info "Please answer yes or no." ;;
        esac
    done
}

expand_path() {
    local path="$1"
    case "$path" in
        '~') printf '%s' "$HOME" ;;
        '~/'*) printf '%s/%s' "$HOME" "${path#~/}" ;;
        *) printf '%s' "$path" ;;
    esac
}

validate_alias() {
    local alias="$1"

    [[ "$alias" =~ ^[A-Za-z0-9._-]+$ ]] || {
        die "Alias may contain only letters, numbers, dots, underscores, and hyphens."
    }
}

validate_tsv_value() {
    local label="$1"
    local value="$2"

    [[ "$value" != *$'\t'* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
        die "$label cannot contain tab or newline characters."
    }
}

load_account() {
    local wanted_alias="$1"
    local line_alias line_host_alias line_host_name line_key_path line_user_name line_user_email

    ACCOUNT_ALIAS=''
    ACCOUNT_HOST_ALIAS=''
    ACCOUNT_HOST_NAME=''
    ACCOUNT_KEY_PATH=''
    ACCOUNT_USER_NAME=''
    ACCOUNT_USER_EMAIL=''

    [[ -f "$ACCOUNTS_FILE" ]] || return 1

    while IFS=$'\t' read -r line_alias line_host_alias line_host_name line_key_path line_user_name line_user_email; do
        [[ -n "${line_alias:-}" ]] || continue
        [[ "$line_alias" == \#* ]] && continue

        if [[ "$line_alias" == "$wanted_alias" ]]; then
            ACCOUNT_ALIAS="$line_alias"
            ACCOUNT_HOST_ALIAS="$line_host_alias"
            ACCOUNT_HOST_NAME="$line_host_name"
            ACCOUNT_KEY_PATH="$line_key_path"
            ACCOUNT_USER_NAME="$line_user_name"
            ACCOUNT_USER_EMAIL="$line_user_email"
            return 0
        fi
    done <"$ACCOUNTS_FILE"

    return 1
}

account_count() {
    local count
    count="$(awk -F '\t' 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$ACCOUNTS_FILE")"
    printf '%s' "$count"
}

first_account_alias() {
    awk -F '\t' 'NF && $1 !~ /^#/ { print $1; exit }' "$ACCOUNTS_FILE"
}

load_account_menu() {
    local line_alias line_host_alias line_host_name line_key_path _line_user_name _line_user_email

    ACCOUNT_MENU_ALIASES=()
    ACCOUNT_MENU_HOST_ALIASES=()
    ACCOUNT_MENU_HOST_NAMES=()
    ACCOUNT_MENU_KEY_PATHS=()

    while IFS=$'\t' read -r line_alias line_host_alias line_host_name line_key_path _line_user_name _line_user_email; do
        [[ -n "${line_alias:-}" ]] || continue
        [[ "$line_alias" == \#* ]] && continue

        ACCOUNT_MENU_ALIASES+=("$line_alias")
        ACCOUNT_MENU_HOST_ALIASES+=("$line_host_alias")
        ACCOUNT_MENU_HOST_NAMES+=("$line_host_name")
        ACCOUNT_MENU_KEY_PATHS+=("$line_key_path")
    done <"$ACCOUNTS_FILE"
}

print_account_menu() {
    local i

    printf 'Saved accounts:\n' >&2
    printf '  %-4s %-20s %-24s %-22s %s\n' "NO." "ALIAS" "SSH HOST" "GIT HOST" "KEY" >&2

    for i in "${!ACCOUNT_MENU_ALIASES[@]}"; do
        printf '  %-4s %-20s %-24s %-22s %s\n' \
            "$((i + 1))." \
            "${ACCOUNT_MENU_ALIASES[$i]}" \
            "${ACCOUNT_MENU_HOST_ALIASES[$i]}" \
            "${ACCOUNT_MENU_HOST_NAMES[$i]}" \
            "${ACCOUNT_MENU_KEY_PATHS[$i]}" >&2
    done
}

draw_account_arrow_menu() {
    local selected="$1"
    local i marker

    printf 'Select account with Up/Down, then Enter:\n' >&2
    for i in "${!ACCOUNT_MENU_ALIASES[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %-20s %-24s %s\n' \
            "$marker" \
            "$((i + 1))" \
            "${ACCOUNT_MENU_ALIASES[$i]}" \
            "${ACCOUNT_MENU_HOST_ALIASES[$i]}" \
            "${ACCOUNT_MENU_KEY_PATHS[$i]}" >&2
    done
}

select_account_arrow() {
    local selected=0
    local key rest lines

    lines=$((${#ACCOUNT_MENU_ALIASES[@]} + 1))
    draw_account_arrow_menu "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                printf '%s\n' "${ACCOUNT_MENU_ALIASES[$selected]}"
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A')
                        if (( selected > 0 )); then
                            selected=$((selected - 1))
                        else
                            selected=$((${#ACCOUNT_MENU_ALIASES[@]} - 1))
                        fi
                        ;;
                    '[B')
                        selected=$(((selected + 1) % ${#ACCOUNT_MENU_ALIASES[@]}))
                        ;;
                esac
                printf '\033[%sA\033[J' "$lines" >&2
                draw_account_arrow_menu "$selected"
                ;;
        esac
    done
}

select_account_numbered() {
    local selected

    print_account_menu

    while true; do
        selected="$(prompt_required "Select account number or alias")"

        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            if (( selected >= 1 && selected <= ${#ACCOUNT_MENU_ALIASES[@]} )); then
                printf '%s' "${ACCOUNT_MENU_ALIASES[$((selected - 1))]}"
                return
            fi
            info "Choose a number from 1 to ${#ACCOUNT_MENU_ALIASES[@]}." >&2
            continue
        fi

        validate_alias "$selected"
        if load_account "$selected"; then
            printf '%s' "$selected"
            return
        fi

        info "Unknown account alias: $selected" >&2
    done
}

repo_path_from_input() {
    local input="$1"
    local repo_path

    if [[ "$input" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
        repo_path="${input%.git}"
        printf '%s' "$repo_path"
        return
    fi

    if [[ "$input" =~ ^https://[^/]+/(.+)$ ]]; then
        repo_path="${BASH_REMATCH[1]}"
        repo_path="${repo_path%.git}"
        printf '%s' "$repo_path"
        return
    fi

    if [[ "$input" =~ ^git@[^:]+:(.+)$ ]]; then
        repo_path="${BASH_REMATCH[1]}"
        repo_path="${repo_path%.git}"
        printf '%s' "$repo_path"
        return
    fi

    if [[ "$input" =~ ^ssh://git@[^/]+/(.+)$ ]]; then
        repo_path="${BASH_REMATCH[1]}"
        repo_path="${repo_path%.git}"
        printf '%s' "$repo_path"
        return
    fi

    die "Repo must be owner/repo, HTTPS URL, or SSH URL."
}

load_repo_menu() {
    local account_alias="$1"
    local line_alias line_repo_path

    REPO_MENU_PATHS=()

    while IFS=$'\t' read -r line_alias line_repo_path; do
        [[ -n "${line_alias:-}" ]] || continue
        [[ "$line_alias" == \#* ]] && continue

        if [[ "$line_alias" == "$account_alias" ]]; then
            REPO_MENU_PATHS+=("$line_repo_path")
        fi
    done <"$REPOS_FILE"
}

print_repo_menu() {
    local account_alias="$1"
    local i
    local fetch_number manual_number

    printf 'Saved repos for account "%s":\n' "$account_alias" >&2
    printf '  %-4s %s\n' "NO." "REPO" >&2

    for i in "${!REPO_MENU_PATHS[@]}"; do
        printf '  %-4s %s\n' "$((i + 1))." "${REPO_MENU_PATHS[$i]}" >&2
    done

    fetch_number=$((${#REPO_MENU_PATHS[@]} + 1))
    manual_number=$((${#REPO_MENU_PATHS[@]} + 2))
    printf '  %-4s %s\n' "${fetch_number}." "Fetch from GitHub with gh" >&2
    printf '  %-4s %s\n' "${manual_number}." "Enter repo manually" >&2
}

draw_repo_arrow_menu() {
    local account_alias="$1"
    local selected="$2"
    local fetch_index="${#REPO_MENU_PATHS[@]}"
    local manual_index=$((${#REPO_MENU_PATHS[@]} + 1))
    local i marker label

    printf 'Select repo for account "%s" with Up/Down, then Enter:\n' "$account_alias" >&2

    for i in "${!REPO_MENU_PATHS[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %s\n' "$marker" "$((i + 1))" "${REPO_MENU_PATHS[$i]}" >&2
    done

    marker=' '
    [[ "$fetch_index" -eq "$selected" ]] && marker='>'
    label='Fetch from GitHub with gh'
    printf ' %s %2s) %s\n' "$marker" "$((fetch_index + 1))" "$label" >&2

    marker=' '
    [[ "$manual_index" -eq "$selected" ]] && marker='>'
    label='Enter repo manually'
    printf ' %s %2s) %s\n' "$marker" "$((manual_index + 1))" "$label" >&2
}

select_repo_arrow() {
    local account_alias="$1"
    local selected=0
    local item_count=$((${#REPO_MENU_PATHS[@]} + 2))
    local fetch_index="${#REPO_MENU_PATHS[@]}"
    local manual_index=$((${#REPO_MENU_PATHS[@]} + 1))
    local key rest lines

    lines=$((item_count + 1))
    draw_repo_arrow_menu "$account_alias" "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                if (( selected == fetch_index )); then
                    printf '%s\n' "__fetch__"
                elif (( selected == manual_index )); then
                    printf '%s\n' "__manual__"
                else
                    printf '%s\n' "${REPO_MENU_PATHS[$selected]}"
                fi
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A')
                        if (( selected > 0 )); then
                            selected=$((selected - 1))
                        else
                            selected=$((item_count - 1))
                        fi
                        ;;
                    '[B')
                        selected=$(((selected + 1) % item_count))
                        ;;
                esac
                printf '\033[%sA\033[J' "$lines" >&2
                draw_repo_arrow_menu "$account_alias" "$selected"
                ;;
        esac
    done
}

select_repo_numbered() {
    local account_alias="$1"
    local selected fetch_number manual_number

    print_repo_menu "$account_alias"
    fetch_number=$((${#REPO_MENU_PATHS[@]} + 1))
    manual_number=$((${#REPO_MENU_PATHS[@]} + 2))

    while true; do
        selected="$(prompt_required "Select repo number, or type owner/repo or URL")"

        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            if (( selected >= 1 && selected <= ${#REPO_MENU_PATHS[@]} )); then
                printf '%s' "${REPO_MENU_PATHS[$((selected - 1))]}"
                return
            fi

            if (( selected == fetch_number )); then
                printf '%s' "__fetch__"
                return
            fi

            if (( selected == manual_number )); then
                printf '%s' "__manual__"
                return
            fi

            info "Choose a number from 1 to $manual_number." >&2
            continue
        fi

        repo_path_from_input "$selected"
        return
    done
}

load_github_repo_menu() {
    local owner="$1"
    local limit="$2"
    local repo_list line

    GITHUB_REPO_MENU_PATHS=()

    if ! command -v gh >/dev/null 2>&1; then
        info "GitHub CLI 'gh' is not installed or not in PATH." >&2
        return 1
    fi

    if ! repo_list="$(gh repo list "$owner" --limit "$limit" --json nameWithOwner --jq '.[].nameWithOwner')"; then
        info "Could not fetch repos with gh. Check gh auth, network, and the user/org name." >&2
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        GITHUB_REPO_MENU_PATHS+=("$line")
    done <<<"$repo_list"

    (( ${#GITHUB_REPO_MENU_PATHS[@]} > 0 ))
}

print_github_repo_menu() {
    local owner="$1"
    local i manual_number

    printf 'Available repos for "%s":\n' "$owner" >&2
    printf '  %-4s %s\n' "NO." "REPO" >&2

    for i in "${!GITHUB_REPO_MENU_PATHS[@]}"; do
        printf '  %-4s %s\n' "$((i + 1))." "${GITHUB_REPO_MENU_PATHS[$i]}" >&2
    done

    manual_number=$((${#GITHUB_REPO_MENU_PATHS[@]} + 1))
    printf '  %-4s %s\n' "${manual_number}." "Enter repo manually" >&2
}

draw_github_repo_arrow_menu() {
    local owner="$1"
    local selected="$2"
    local manual_index="${#GITHUB_REPO_MENU_PATHS[@]}"
    local i marker

    printf 'Select available repo for "%s" with Up/Down, then Enter:\n' "$owner" >&2

    for i in "${!GITHUB_REPO_MENU_PATHS[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %s\n' "$marker" "$((i + 1))" "${GITHUB_REPO_MENU_PATHS[$i]}" >&2
    done

    marker=' '
    [[ "$manual_index" -eq "$selected" ]] && marker='>'
    printf ' %s %2s) %s\n' "$marker" "$((manual_index + 1))" "Enter repo manually" >&2
}

select_github_repo_arrow() {
    local owner="$1"
    local selected=0
    local item_count=$((${#GITHUB_REPO_MENU_PATHS[@]} + 1))
    local manual_index="${#GITHUB_REPO_MENU_PATHS[@]}"
    local key rest lines

    lines=$((item_count + 1))
    draw_github_repo_arrow_menu "$owner" "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                if (( selected == manual_index )); then
                    printf '%s\n' "__manual__"
                else
                    printf '%s\n' "${GITHUB_REPO_MENU_PATHS[$selected]}"
                fi
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A')
                        if (( selected > 0 )); then
                            selected=$((selected - 1))
                        else
                            selected=$((item_count - 1))
                        fi
                        ;;
                    '[B')
                        selected=$(((selected + 1) % item_count))
                        ;;
                esac
                printf '\033[%sA\033[J' "$lines" >&2
                draw_github_repo_arrow_menu "$owner" "$selected"
                ;;
        esac
    done
}

select_github_repo_numbered() {
    local owner="$1"
    local selected manual_number

    print_github_repo_menu "$owner"
    manual_number=$((${#GITHUB_REPO_MENU_PATHS[@]} + 1))

    while true; do
        selected="$(prompt_required "Select repo number, or type owner/repo or URL")"

        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            if (( selected >= 1 && selected <= ${#GITHUB_REPO_MENU_PATHS[@]} )); then
                printf '%s' "${GITHUB_REPO_MENU_PATHS[$((selected - 1))]}"
                return
            fi

            if (( selected == manual_number )); then
                printf '%s' "__manual__"
                return
            fi

            info "Choose a number from 1 to $manual_number." >&2
            continue
        fi

        repo_path_from_input "$selected"
        return
    done
}

choose_github_repo_input() {
    local owner limit selected repo_input

    owner="$(prompt_required "GitHub user/org to list repos")"
    limit="$(prompt_default "Max repos to fetch" "100")"

    if [[ ! "$limit" =~ ^[0-9]+$ || "$limit" -lt 1 ]]; then
        die "Max repos must be a positive number."
    fi

    if ! load_github_repo_menu "$owner" "$limit"; then
        repo_input="$(prompt_required "Repo path or URL, e.g. owner/repo")"
        repo_path_from_input "$repo_input"
        return
    fi

    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        selected="$(select_github_repo_arrow "$owner")"
    else
        selected="$(select_github_repo_numbered "$owner")"
    fi

    if [[ "$selected" == "__manual__" ]]; then
        repo_input="$(prompt_required "Repo path or URL, e.g. owner/repo")"
        repo_path_from_input "$repo_input"
        return
    fi

    repo_path_from_input "$selected"
}

choose_repo_input() {
    local account_alias="$1"
    local selected repo_input

    load_repo_menu "$account_alias"

    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        selected="$(select_repo_arrow "$account_alias")"
    else
        selected="$(select_repo_numbered "$account_alias")"
    fi

    if [[ "$selected" == "__fetch__" ]]; then
        choose_github_repo_input
        return
    fi

    if [[ "$selected" != "__manual__" ]]; then
        printf '%s' "$selected"
        return
    fi

    repo_input="$(prompt_required "Repo path or URL, e.g. owner/repo")"
    repo_path_from_input "$repo_input"
}

print_mode_menu() {
    printf 'Choose how to apply this repo:\n' >&2
    printf '  %-4s %-8s %s\n' "NO." "MODE" "ACTION" >&2
    printf '  %-4s %-8s %s\n' "1." "current" "Configure the current directory" >&2
    printf '  %-4s %-8s %s\n' "2." "path" "Configure another local directory" >&2
    printf '  %-4s %-8s %s\n' "3." "clone" "Clone into a new/existing empty directory" >&2
}

draw_mode_arrow_menu() {
    local selected="$1"
    local modes=("current" "path" "clone")
    local labels=("Configure the current directory" "Configure another local directory" "Clone into a new/existing empty directory")
    local i marker

    printf 'Choose how to apply this repo with Up/Down, then Enter:\n' >&2
    for i in "${!modes[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %-8s %s\n' "$marker" "$((i + 1))" "${modes[$i]}" "${labels[$i]}" >&2
    done
}

select_mode_arrow() {
    local modes=("current" "path" "clone")
    local selected=0
    local key rest lines

    lines=$((${#modes[@]} + 1))
    draw_mode_arrow_menu "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                printf '%s\n' "${modes[$selected]}"
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A')
                        if (( selected > 0 )); then
                            selected=$((selected - 1))
                        else
                            selected=$((${#modes[@]} - 1))
                        fi
                        ;;
                    '[B')
                        selected=$(((selected + 1) % ${#modes[@]}))
                        ;;
                esac
                printf '\033[%sA\033[J' "$lines" >&2
                draw_mode_arrow_menu "$selected"
                ;;
        esac
    done
}

select_mode_numbered() {
    local selected

    print_mode_menu

    while true; do
        selected="$(prompt_required "Select mode number or name")"

        case "$selected" in
            1|current)
                printf '%s' "current"
                return
                ;;
            2|path)
                printf '%s' "path"
                return
                ;;
            3|clone)
                printf '%s' "clone"
                return
                ;;
            *)
                info "Choose 1, 2, 3, current, path, or clone." >&2
                ;;
        esac
    done
}

choose_repo_mode() {
    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        select_mode_arrow
    else
        select_mode_numbered
    fi
}

save_repo() {
    local alias="$1"
    local repo_path="$2"
    local tmp_file

    validate_tsv_value "Repo path" "$repo_path"

    tmp_file="$(mktemp)"
    awk -F '\t' -v alias="$alias" -v repo_path="$repo_path" '
        BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        !($1 == alias && $2 == repo_path) { print }
    ' "$REPOS_FILE" >"$tmp_file"
    printf '%s\t%s\n' "$alias" "$repo_path" >>"$tmp_file"
    mv "$tmp_file" "$REPOS_FILE"
    chmod 600 "$REPOS_FILE" 2>/dev/null || true
}

delete_account_repos() {
    local alias="$1"
    local tmp_file

    tmp_file="$(mktemp)"
    awk -F '\t' -v alias="$alias" '
        BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        $1 != alias { print }
    ' "$REPOS_FILE" >"$tmp_file"
    mv "$tmp_file" "$REPOS_FILE"
    chmod 600 "$REPOS_FILE" 2>/dev/null || true
}

save_account() {
    local alias="$1"
    local host_alias="$2"
    local host_name="$3"
    local key_path="$4"
    local user_name="$5"
    local user_email="$6"
    local tmp_file

    tmp_file="$(mktemp)"
    awk -F '\t' -v alias="$alias" '
        BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        $1 != alias { print }
    ' "$ACCOUNTS_FILE" >"$tmp_file"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$alias" "$host_alias" "$host_name" "$key_path" "$user_name" "$user_email" >>"$tmp_file"
    mv "$tmp_file" "$ACCOUNTS_FILE"
    chmod 600 "$ACCOUNTS_FILE" 2>/dev/null || true
}

delete_account_record() {
    local alias="$1"
    local tmp_file

    tmp_file="$(mktemp)"
    awk -F '\t' -v alias="$alias" '
        BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        $1 != alias { print }
    ' "$ACCOUNTS_FILE" >"$tmp_file"
    mv "$tmp_file" "$ACCOUNTS_FILE"
    chmod 600 "$ACCOUNTS_FILE" 2>/dev/null || true
}

remove_ssh_block() {
    local alias="$1"
    local tmp_file

    tmp_file="$(mktemp)"
    awk -v alias="$alias" '
        $0 == "# multi_git account: " alias { skip = 1; next }
        $0 == "# end multi_git account: " alias { skip = 0; next }
        !skip { print }
    ' "$SSH_CONFIG" >"$tmp_file"
    mv "$tmp_file" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG" 2>/dev/null || true
}

write_ssh_block() {
    local alias="$1"
    local host_alias="$2"
    local host_name="$3"
    local key_path="$4"

    remove_ssh_block "$alias"

    {
        printf '\n'
        printf '# multi_git account: %s\n' "$alias"
        printf 'Host %s\n' "$host_alias"
        printf '    HostName %s\n' "$host_name"
        printf '    User git\n'
        printf '    IdentityFile %s\n' "$key_path"
        printf '    IdentitiesOnly yes\n'
        printf '# end multi_git account: %s\n' "$alias"
    } >>"$SSH_CONFIG"

    chmod 600 "$SSH_CONFIG" 2>/dev/null || true
}

print_public_key_instructions() {
    local key_path="$1"
    local public_key="${key_path}.pub"

    if [[ -f "$public_key" ]]; then
        info ""
        info "Add this public key to the matching Git provider account:"
        info ""
        cat "$public_key"
        info ""
        info "For GitHub: Settings -> SSH and GPG keys -> New SSH key."
    else
        info "Public key was not found at: $public_key"
    fi
}

choose_account_alias() {
    local provided_alias="${1:-}"
    local count selected

    count="$(account_count)"
    [[ "$count" != "0" ]] || die "No accounts found. Run: ./multi_git.sh add acc"
    load_account_menu

    if [[ -n "$provided_alias" ]]; then
        print_account_menu
        validate_alias "$provided_alias"
        load_account "$provided_alias" || die "Unknown account alias: $provided_alias"
        printf '%s' "$provided_alias"
        return
    fi

    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        selected="$(select_account_arrow)"
    else
        selected="$(select_account_numbered)"
    fi

    validate_alias "$selected"
    load_account "$selected" || die "Unknown account alias: $selected"
    printf '%s' "$selected"
}

list_accounts() {
    ensure_config

    if [[ "$(account_count)" == "0" ]]; then
        info "No accounts saved yet."
        return
    fi

    printf '%-20s %-24s %-22s %s\n' "ALIAS" "SSH HOST" "GIT HOST" "KEY"
    awk -F '\t' '
        NF && $1 !~ /^#/ {
            printf "%-20s %-24s %-22s %s\n", $1, $2, $3, $4
        }
    ' "$ACCOUNTS_FILE"
}

add_account() {
    local alias="${1:-}"
    local host_alias host_name key_path default_key_path user_name user_email

    ensure_config

    if [[ -z "$alias" ]]; then
        alias="$(prompt_required "Account alias, e.g. personal or company")"
    fi

    validate_alias "$alias"

    if load_account "$alias"; then
        info "Account '$alias' already exists."
        confirm "Update it?" "no" || return
    fi

    host_alias="$(prompt_default "SSH host alias" "github-${alias}")"
    host_name="$(prompt_default "Git host name" "github.com")"
    user_name="$(prompt_required "Git commit user.name for this account")"
    user_email="$(prompt_required "Git commit user.email for this account")"
    default_key_path="${SSH_DIR}/id_ed25519_${alias}"
    key_path="$(prompt_default "SSH key path" "$default_key_path")"
    key_path="$(expand_path "$key_path")"

    validate_tsv_value "Alias" "$alias"
    validate_tsv_value "SSH host alias" "$host_alias"
    validate_tsv_value "Git host name" "$host_name"
    validate_tsv_value "SSH key path" "$key_path"
    validate_tsv_value "Git user.name" "$user_name"
    validate_tsv_value "Git user.email" "$user_email"

    if [[ ! -f "$key_path" ]]; then
        mkdir -p "$(dirname "$key_path")"
        info "Generating SSH key: $key_path"
        if confirm "Protect this SSH key with a passphrase? ssh-keygen will prompt for it." "yes"; then
            ssh-keygen -t ed25519 -C "$user_email" -f "$key_path"
        else
            ssh-keygen -t ed25519 -C "$user_email" -f "$key_path" -N ''
        fi
    else
        info "Reusing existing SSH key: $key_path"
        if [[ ! -f "${key_path}.pub" ]]; then
            info "Generating missing public key: ${key_path}.pub"
            ssh-keygen -y -f "$key_path" >"${key_path}.pub"
        fi
    fi

    write_ssh_block "$alias" "$host_alias" "$host_name" "$key_path"
    save_account "$alias" "$host_alias" "$host_name" "$key_path" "$user_name" "$user_email"

    info ""
    info "Saved account '$alias'."
    print_public_key_instructions "$key_path"

    if confirm "Test SSH connection now? Only do this after adding the public key." "no"; then
        ssh -T "git@${host_alias}" || true
    fi
}

delete_account() {
    local alias="${1:-}"

    ensure_config

    if [[ -z "$alias" ]]; then
        list_accounts
        alias="$(prompt_required "Account alias to delete")"
    fi

    validate_alias "$alias"
    load_account "$alias" || die "Unknown account alias: $alias"

    info "This removes the local multi_git account record and SSH config block for '$alias'."
    confirm "Continue?" "no" || return

    remove_ssh_block "$alias"
    delete_account_record "$alias"
    delete_account_repos "$alias"
    info "Removed account '$alias' from multi_git and SSH config."

    if [[ -f "$ACCOUNT_KEY_PATH" || -f "${ACCOUNT_KEY_PATH}.pub" ]]; then
        if confirm "Delete SSH key files for '$alias'?" "no"; then
            rm -f "$ACCOUNT_KEY_PATH" "${ACCOUNT_KEY_PATH}.pub"
            info "Deleted key files."
        else
            info "Kept key files."
        fi
    fi
}

repo_name_from_path() {
    local repo_path="$1"
    repo_path="${repo_path%.git}"
    printf '%s' "${repo_path##*/}"
}

normalize_repo_remote() {
    local input="$1"
    local host_alias="$2"
    local repo_path

    repo_path="$(repo_path_from_input "$input")"
    printf 'git@%s:%s.git' "$host_alias" "$repo_path"
}

ensure_git_available() {
    command -v git >/dev/null 2>&1 || die "git is not installed or not in PATH."
}

is_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

is_git_repo_dir() {
    local repo_dir="$1"
    git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

directory_has_data() {
    local repo_dir="${1:-.}"
    [[ -n "$(find "$repo_dir" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)" ]]
}

configure_repo_identity() {
    local repo_dir="$1"
    local remote_url="$2"

    git -C "$repo_dir" config user.name "$ACCOUNT_USER_NAME"
    git -C "$repo_dir" config user.email "$ACCOUNT_USER_EMAIL"

    if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
        info "Current origin: $(git -C "$repo_dir" remote get-url origin)"
        confirm "Replace origin with $remote_url?" "yes" || return
        git -C "$repo_dir" remote set-url origin "$remote_url"
    else
        git -C "$repo_dir" remote add origin "$remote_url"
    fi

    info "Configured repo identity:"
    info "  user.name:  $(git -C "$repo_dir" config user.name)"
    info "  user.email: $(git -C "$repo_dir" config user.email)"
    info "  origin:     $(git -C "$repo_dir" remote get-url origin)"
}

configure_repo_directory() {
    local repo_dir="$1"
    local remote_url="$2"

    repo_dir="$(expand_path "$repo_dir")"

    if [[ ! -e "$repo_dir" ]]; then
        confirm "Directory does not exist. Create and initialize it?" "no" || return
        mkdir -p "$repo_dir"
    fi

    [[ -d "$repo_dir" ]] || die "Not a directory: $repo_dir"

    if ! is_git_repo_dir "$repo_dir"; then
        if directory_has_data "$repo_dir"; then
            confirm "Initialize Git in this non-empty directory: $repo_dir?" "no" || return
        fi
        git -C "$repo_dir" init
    fi

    configure_repo_identity "$repo_dir" "$remote_url"
}

add_repo() {
    local alias="${1:-}"
    local repo_input="${2:-}"
    local selected_alias repo_path remote_url mode destination repo_name target_dir

    ensure_config
    ensure_git_available

    selected_alias="$(choose_account_alias "$alias")"
    load_account "$selected_alias" || die "Unknown account alias: $selected_alias"

    if [[ -z "$repo_input" ]]; then
        repo_path="$(choose_repo_input "$selected_alias")"
    else
        repo_path="$(repo_path_from_input "$repo_input")"
    fi

    save_repo "$selected_alias" "$repo_path"
    remote_url="$(normalize_repo_remote "$repo_path" "$ACCOUNT_HOST_ALIAS")"

    if ! is_git_repo && directory_has_data "."; then
        info "Current directory has files but is not a Git repo."
    fi
    mode="$(choose_repo_mode)"

    case "$mode" in
        current)
            configure_repo_directory "." "$remote_url"
            ;;
        path)
            target_dir="$(prompt_default "Repo directory" ".")"
            configure_repo_directory "$target_dir" "$remote_url"
            ;;
        clone)
            repo_name="$(repo_name_from_path "$repo_path")"
            destination="$(prompt_default "Clone destination" "$repo_name")"
            if [[ -e "$destination" && -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                die "Destination exists and is not empty: $destination"
            fi
            git clone "$remote_url" "$destination"
            configure_repo_identity "$destination" "$remote_url"
            ;;
        *)
            die "Expected current, path, or clone."
            ;;
    esac
}

delete_repo() {
    ensure_git_available
    is_git_repo || die "Current directory is not inside a Git repo."

    if git remote get-url origin >/dev/null 2>&1; then
        info "Current origin: $(git remote get-url origin)"
        if confirm "Remove origin from this repo?" "no"; then
            git remote remove origin
            info "Removed origin."
        fi
    else
        info "This repo has no origin remote."
    fi

    if confirm "Unset local user.name and user.email for this repo?" "no"; then
        git config --unset user.name 2>/dev/null || true
        git config --unset user.email 2>/dev/null || true
        info "Unset local Git identity."
    fi
}

list_repo() {
    ensure_git_available
    is_git_repo || die "Current directory is not inside a Git repo."

    info "Repo: $(git rev-parse --show-toplevel)"
    info "Branch: $(git branch --show-current 2>/dev/null || true)"

    if git remote get-url origin >/dev/null 2>&1; then
        info "Origin: $(git remote get-url origin)"
    else
        info "Origin: not set"
    fi

    info "user.name:  $(git config user.name 2>/dev/null || true)"
    info "user.email: $(git config user.email 2>/dev/null || true)"
}

main() {
    local command="${1:-help}"
    local target="${2:-}"

    case "$command:$target" in
        help:*|--help:*|-h:*)
            usage
            ;;
        add:acc|add:account)
            add_account "${3:-}"
            ;;
        del:acc|del:account|delete:acc|delete:account|remove:acc|remove:account)
            delete_account "${3:-}"
            ;;
        list:acc|list:account|ls:acc|ls:account)
            list_accounts
            ;;
        add:repo|add:repository)
            add_repo "${3:-}" "${4:-}"
            ;;
        del:repo|del:repository|delete:repo|delete:repository|remove:repo|remove:repository)
            delete_repo
            ;;
        list:repo|list:repository|ls:repo|ls:repository)
            list_repo
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
