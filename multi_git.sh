#!/usr/bin/env bash

set -euo pipefail

APP_NAME="multi_git"
CONFIG_DIR="${MULTI_GIT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/${APP_NAME}}"
ACCOUNTS_FILE="${CONFIG_DIR}/accounts.tsv"
REPOS_FILE="${CONFIG_DIR}/repos.tsv"
SSH_DIR="${MULTI_GIT_SSH_DIR:-${HOME}/.ssh}"
SSH_CONFIG="${SSH_DIR}/config"
LIBSECRET_INSTALL_DIR="${MULTI_GIT_LIBEXEC_DIR:-${HOME}/.local/libexec/multi_git}"
LIBSECRET_HELPER_PATH="${LIBSECRET_INSTALL_DIR}/git-credential-libsecret"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

usage() {
    cat <<EOF
multi_git.sh - interactive helper for multiple Git accounts and servers

Usage:
  ./multi_git.sh
  ./multi_git.sh menu
  ./multi_git.sh help
  ./multi_git.sh add acc [alias]
  ./multi_git.sh del acc [alias]
  ./multi_git.sh list acc
  ./multi_git.sh add repo [alias] [repo-path-or-url]
  ./multi_git.sh del repo
  ./multi_git.sh list repo

What it does:
  menu      Open the persistent interactive main menu. After each action,
            press Enter to return. The script exits only when Quit is chosen.
  add acc   Add an SSH-key account or an HTTPS username/password account,
            and save local-only Git identity metadata.
  add repo  Configure the current Git repo or clone a repo using one of the
            saved account aliases, then set local user.name/user.email.
  del acc   Remove a saved account and, for SSH accounts, its managed
            SSH config block.
  del repo  Remove origin from the current repo and optionally unset identity.

Resolved local storage paths:
  Account registry:  ${ACCOUNTS_FILE}
  Saved repo list:   ${REPOS_FILE}
  SSH configuration: ${SSH_CONFIG}

The public script:
  multi_git.sh contains no built-in names, emails, usernames, passwords,
  server addresses, repository names, or private keys. All real values are
  requested interactively and written only to files on the machine where the
  script runs.

multi_git account registry:
  ${ACCOUNTS_FILE}

  Stores one record per account alias. Depending on authentication type, a
  record can contain:
    - Account alias and authentication type (ssh or https).
    - Git server hostname and SSH host alias, or HTTPS server base URL.
    - SSH private-key path, or HTTPS username.
    - Commit identity: Git user.name and user.email.

  It does NOT contain:
    - SSH private-key contents.
    - SSH key passphrases.
    - HTTPS passwords or access tokens.
    - Cached credentials from Git's credential helper.

  The config directory is mode 700 and registry files are mode 600 where the
  operating system supports Unix permissions.

Saved repository registry:
  ${REPOS_FILE}

  Stores account-alias to repository-path mappings, such as team/project.
  This list powers the interactive repo picker. It is only a local convenience
  index; it does not clone, mirror, or contain repository data.

SSH authentication storage:
  - Private and public keys are separate files at the key path selected while
    adding the account, normally under ${SSH_DIR}.
  - The private key never enters the multi_git registry; only its path does.
  - Managed host blocks are written to:
      ${SSH_CONFIG}
    between comments named "multi_git account: <alias>" and
    "end multi_git account: <alias>".
  - SSH key passphrases are handled by ssh-keygen, ssh-agent, or the terminal.
    multi_git never reads or stores the passphrase.
  - A configured repo stores an SSH origin URL in its .git/config, for example
    git@git-account-alias:team/project.git.

HTTPS username/password authentication storage:
  - The account registry stores the server base URL and username, but no
    password:
      ${ACCOUNTS_FILE}
  - The username and credential.useHttpPath setting are written with
    "git config --global" for the current operating-system user, scoped to the
    server URL. Run "git config --global --show-origin --get-regexp
    '^credential\\.'" to inspect those settings and their source file.
  - On Linux, when git-credential-libsecret is missing, multi_git asks whether
    it should install the required distribution packages and build Git's
    libsecret helper at:
      ${LIBSECRET_HELPER_PATH}
    The helper stores credentials persistently through the Linux Secret
    Service/keyring. A working desktop keyring or Secret Service session is
    required when credentials are stored or retrieved.
  - If libsecret installation is declined or fails, multi_git can configure
    "cache --timeout=28800" as a fallback. The fallback keeps the password
    only in memory for eight hours and does not write it to disk.
  - A helper named "store" writes credentials unencrypted to disk and is not
    configured by this script.
  - Helpers such as Git Credential Manager or a working libsecret helper may
    store credentials in the operating system's credential vault. Their own
    storage and security policy applies.
  - If no helper is configured, Git prompts for the password/token whenever it
    needs authentication. Some servers require an access token entered in the
    password field instead of the account password.
  - Plain HTTP can expose credentials in transit. Use an https:// server URL
    whenever the server supports it.

What is stored inside each repository's .git/config:
  - origin remote URL.
  - Branch tracking information created by Git.
  - Repo-specific commit identity: user.name and user.email.

  multi_git removes credential.helper, credential.username, and
  credential.useHttpPath from the repo-local config. Authentication helpers
  are intentionally OS-global so a shared working copy does not carry a
  Linux-only helper into Windows or a Windows-only helper into Linux.

Shared Windows/Linux repositories:
  - The shared .git/config contains the remote and commit identity, but no
    operating-system-specific credential helper.
  - Linux uses the Linux user's global Git config, normally ~/.gitconfig.
  - Windows uses the Windows user's global Git config and can use Git
    Credential Manager independently.
  - Configuring or changing a credential helper on one OS therefore does not
    alter the helper selected by the other OS.

Deletion behavior:
  - "del acc" removes the account registry entry, its saved repo choices, and
    its managed SSH block. SSH key files are deleted only after confirmation.
  - "del acc" does not erase credentials previously retained by an external
    OS credential helper or remove URL-scoped entries from global Git config.
  - "del repo" removes origin only after confirmation and can unset the local
    commit identity. It does not delete the directory, Git history, working
    files, or the repository on the server.

Path overrides:
  - MULTI_GIT_CONFIG_DIR overrides the complete multi_git config directory.
  - XDG_CONFIG_HOME changes the default config root when the first override is
    not set.
  - MULTI_GIT_SSH_DIR overrides the SSH directory.
  - MULTI_GIT_LIBEXEC_DIR overrides the user-local helper installation
    directory.
EOF
}

ensure_config() {
    mkdir -p "$CONFIG_DIR" "$SSH_DIR"
    chmod 700 "$CONFIG_DIR" "$SSH_DIR" 2>/dev/null || true

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        {
            printf '# alias\tauth_type\thost_alias\thost_name\tkey_path\tauth_username\tbase_url\tuser_name\tuser_email\n'
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

parse_account_line() {
    local line="$1"
    local fields=()

    IFS=$'\t' read -r -a fields <<<"$line"

    PARSED_ACCOUNT_ALIAS="${fields[0]:-}"
    [[ -n "$PARSED_ACCOUNT_ALIAS" && "$PARSED_ACCOUNT_ALIAS" != \#* ]] || return 1

    if [[ "${fields[1]:-}" == "ssh" || "${fields[1]:-}" == "https" ]]; then
        PARSED_ACCOUNT_AUTH_TYPE="${fields[1]}"
        PARSED_ACCOUNT_HOST_ALIAS="${fields[2]:--}"
        PARSED_ACCOUNT_HOST_NAME="${fields[3]:--}"
        PARSED_ACCOUNT_KEY_PATH="${fields[4]:--}"
        PARSED_ACCOUNT_AUTH_USERNAME="${fields[5]:--}"
        PARSED_ACCOUNT_BASE_URL="${fields[6]:--}"
        PARSED_ACCOUNT_USER_NAME="${fields[7]:-}"
        PARSED_ACCOUNT_USER_EMAIL="${fields[8]:-}"
    else
        # Backward compatibility for the original SSH-only six-column format.
        PARSED_ACCOUNT_AUTH_TYPE='ssh'
        PARSED_ACCOUNT_HOST_ALIAS="${fields[1]:-}"
        PARSED_ACCOUNT_HOST_NAME="${fields[2]:-}"
        PARSED_ACCOUNT_KEY_PATH="${fields[3]:-}"
        PARSED_ACCOUNT_AUTH_USERNAME='git'
        PARSED_ACCOUNT_BASE_URL='-'
        PARSED_ACCOUNT_USER_NAME="${fields[4]:-}"
        PARSED_ACCOUNT_USER_EMAIL="${fields[5]:-}"
    fi
}

load_account() {
    local wanted_alias="$1"
    local line

    ACCOUNT_ALIAS=''
    ACCOUNT_AUTH_TYPE=''
    ACCOUNT_HOST_ALIAS=''
    ACCOUNT_HOST_NAME=''
    ACCOUNT_KEY_PATH=''
    ACCOUNT_AUTH_USERNAME=''
    ACCOUNT_BASE_URL=''
    ACCOUNT_USER_NAME=''
    ACCOUNT_USER_EMAIL=''

    [[ -f "$ACCOUNTS_FILE" ]] || return 1

    while IFS= read -r line; do
        parse_account_line "$line" || continue

        if [[ "$PARSED_ACCOUNT_ALIAS" == "$wanted_alias" ]]; then
            ACCOUNT_ALIAS="$PARSED_ACCOUNT_ALIAS"
            ACCOUNT_AUTH_TYPE="$PARSED_ACCOUNT_AUTH_TYPE"
            ACCOUNT_HOST_ALIAS="$PARSED_ACCOUNT_HOST_ALIAS"
            ACCOUNT_HOST_NAME="$PARSED_ACCOUNT_HOST_NAME"
            ACCOUNT_KEY_PATH="$PARSED_ACCOUNT_KEY_PATH"
            ACCOUNT_AUTH_USERNAME="$PARSED_ACCOUNT_AUTH_USERNAME"
            ACCOUNT_BASE_URL="$PARSED_ACCOUNT_BASE_URL"
            ACCOUNT_USER_NAME="$PARSED_ACCOUNT_USER_NAME"
            ACCOUNT_USER_EMAIL="$PARSED_ACCOUNT_USER_EMAIL"
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
    local line display_auth

    ACCOUNT_MENU_ALIASES=()
    ACCOUNT_MENU_AUTH_TYPES=()
    ACCOUNT_MENU_HOST_NAMES=()
    ACCOUNT_MENU_AUTH_DETAILS=()

    while IFS= read -r line; do
        parse_account_line "$line" || continue

        if [[ "$PARSED_ACCOUNT_AUTH_TYPE" == "ssh" ]]; then
            display_auth="$PARSED_ACCOUNT_HOST_ALIAS -> $PARSED_ACCOUNT_KEY_PATH"
        else
            display_auth="username: $PARSED_ACCOUNT_AUTH_USERNAME"
        fi

        ACCOUNT_MENU_ALIASES+=("$PARSED_ACCOUNT_ALIAS")
        ACCOUNT_MENU_AUTH_TYPES+=("$PARSED_ACCOUNT_AUTH_TYPE")
        ACCOUNT_MENU_HOST_NAMES+=("$PARSED_ACCOUNT_HOST_NAME")
        ACCOUNT_MENU_AUTH_DETAILS+=("$display_auth")
    done <"$ACCOUNTS_FILE"
}

print_account_menu() {
    local i

    printf 'Saved accounts:\n' >&2
    printf '  %-4s %-20s %-8s %-24s %s\n' "NO." "ALIAS" "TYPE" "SERVER" "AUTH" >&2

    for i in "${!ACCOUNT_MENU_ALIASES[@]}"; do
        printf '  %-4s %-20s %-8s %-24s %s\n' \
            "$((i + 1))." \
            "${ACCOUNT_MENU_ALIASES[$i]}" \
            "${ACCOUNT_MENU_AUTH_TYPES[$i]}" \
            "${ACCOUNT_MENU_HOST_NAMES[$i]}" \
            "${ACCOUNT_MENU_AUTH_DETAILS[$i]}" >&2
    done
}

draw_account_arrow_menu() {
    local selected="$1"
    local i marker

    printf 'Select account with Up/Down, then Enter:\n' >&2
    for i in "${!ACCOUNT_MENU_ALIASES[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %-20s %-8s %-24s %s\n' \
            "$marker" \
            "$((i + 1))" \
            "${ACCOUNT_MENU_ALIASES[$i]}" \
            "${ACCOUNT_MENU_AUTH_TYPES[$i]}" \
            "${ACCOUNT_MENU_HOST_NAMES[$i]}" \
            "${ACCOUNT_MENU_AUTH_DETAILS[$i]}" >&2
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
    local account_base_url="${ACCOUNT_BASE_URL:-}"

    if [[ "${ACCOUNT_AUTH_TYPE:-}" == "https" && "$account_base_url" != "-" && "$input" == "${account_base_url%/}/"* ]]; then
        repo_path="${input#"${account_base_url%/}/"}"
        repo_path="${repo_path%.git}"
        printf '%s' "$repo_path"
        return
    fi

    if [[ "$input" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*(\.git)?$ ]]; then
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

    die "Repo must be a repo path, HTTPS URL, or SSH URL."
}

load_repo_menu() {
    local account_alias="$1"
    local line_alias line_repo_path

    REPO_MENU_PATHS=()
    REPO_GITHUB_FETCH_ENABLED=0
    [[ "$ACCOUNT_HOST_NAME" == "github.com" ]] && REPO_GITHUB_FETCH_ENABLED=1

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
    local fetch_number manual_number extra_items=0

    printf 'Saved repos for account "%s":\n' "$account_alias" >&2
    printf '  %-4s %s\n' "NO." "REPO" >&2

    for i in "${!REPO_MENU_PATHS[@]}"; do
        printf '  %-4s %s\n' "$((i + 1))." "${REPO_MENU_PATHS[$i]}" >&2
    done

    if (( REPO_GITHUB_FETCH_ENABLED )); then
        fetch_number=$((${#REPO_MENU_PATHS[@]} + 1))
        extra_items=1
        printf '  %-4s %s\n' "${fetch_number}." "Fetch from GitHub with gh" >&2
    fi
    manual_number=$((${#REPO_MENU_PATHS[@]} + extra_items + 1))
    printf '  %-4s %s\n' "${manual_number}." "Enter repo manually" >&2
}

draw_repo_arrow_menu() {
    local account_alias="$1"
    local selected="$2"
    local fetch_index=-1
    local manual_index="${#REPO_MENU_PATHS[@]}"
    local i marker label

    printf 'Select repo for account "%s" with Up/Down, then Enter:\n' "$account_alias" >&2

    for i in "${!REPO_MENU_PATHS[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %s\n' "$marker" "$((i + 1))" "${REPO_MENU_PATHS[$i]}" >&2
    done

    if (( REPO_GITHUB_FETCH_ENABLED )); then
        fetch_index="${#REPO_MENU_PATHS[@]}"
        manual_index=$((${#REPO_MENU_PATHS[@]} + 1))
        marker=' '
        [[ "$fetch_index" -eq "$selected" ]] && marker='>'
        label='Fetch from GitHub with gh'
        printf ' %s %2s) %s\n' "$marker" "$((fetch_index + 1))" "$label" >&2
    fi

    marker=' '
    [[ "$manual_index" -eq "$selected" ]] && marker='>'
    label='Enter repo manually'
    printf ' %s %2s) %s\n' "$marker" "$((manual_index + 1))" "$label" >&2
}

select_repo_arrow() {
    local account_alias="$1"
    local selected=0
    local item_count=$((${#REPO_MENU_PATHS[@]} + 1 + REPO_GITHUB_FETCH_ENABLED))
    local fetch_index=-1
    local manual_index="${#REPO_MENU_PATHS[@]}"
    local key rest lines

    if (( REPO_GITHUB_FETCH_ENABLED )); then
        fetch_index="${#REPO_MENU_PATHS[@]}"
        manual_index=$((${#REPO_MENU_PATHS[@]} + 1))
    fi

    lines=$((item_count + 1))
    draw_repo_arrow_menu "$account_alias" "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                if (( REPO_GITHUB_FETCH_ENABLED && selected == fetch_index )); then
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
    local selected fetch_number=-1 manual_number extra_items=0

    print_repo_menu "$account_alias"
    if (( REPO_GITHUB_FETCH_ENABLED )); then
        fetch_number=$((${#REPO_MENU_PATHS[@]} + 1))
        extra_items=1
    fi
    manual_number=$((${#REPO_MENU_PATHS[@]} + extra_items + 1))

    while true; do
        selected="$(prompt_required "Select repo number, or type namespace/repo or URL")"

        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            if (( selected >= 1 && selected <= ${#REPO_MENU_PATHS[@]} )); then
                printf '%s' "${REPO_MENU_PATHS[$((selected - 1))]}"
                return
            fi

            if (( REPO_GITHUB_FETCH_ENABLED && selected == fetch_number )); then
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
        selected="$(prompt_required "Select repo number, or type namespace/repo or URL")"

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
        repo_input="$(prompt_required "Repo path or URL, e.g. namespace/repo")"
        repo_path_from_input "$repo_input"
        return
    fi

    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        selected="$(select_github_repo_arrow "$owner")"
    else
        selected="$(select_github_repo_numbered "$owner")"
    fi

    if [[ "$selected" == "__manual__" ]]; then
        repo_input="$(prompt_required "Repo path or URL, e.g. namespace/repo")"
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

    repo_input="$(prompt_required "Repo path or URL, e.g. namespace/repo")"
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

draw_auth_type_arrow_menu() {
    local selected="$1"
    local auth_types=("ssh" "https")
    local labels=("SSH key" "HTTPS username/password")
    local i marker

    printf 'Select authentication type with Up/Down, then Enter:\n' >&2
    for i in "${!auth_types[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %-8s %s\n' "$marker" "$((i + 1))" "${auth_types[$i]}" "${labels[$i]}" >&2
    done
}

select_auth_type_arrow() {
    local default_type="${1:-ssh}"
    local auth_types=("ssh" "https")
    local selected=0
    local key rest lines

    [[ "$default_type" == "https" ]] && selected=1
    lines=$((${#auth_types[@]} + 1))
    draw_auth_type_arrow_menu "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                printf '%s\n' "${auth_types[$selected]}"
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A'|'[B') selected=$(((selected + 1) % ${#auth_types[@]})) ;;
                esac
                printf '\033[%sA\033[J' "$lines" >&2
                draw_auth_type_arrow_menu "$selected"
                ;;
        esac
    done
}

select_auth_type_numbered() {
    local default_type="${1:-ssh}"
    local selected default_number=1

    [[ "$default_type" == "https" ]] && default_number=2
    printf 'Authentication type:\n' >&2
    printf '  1. ssh    SSH key\n' >&2
    printf '  2. https  HTTPS username/password\n' >&2

    while true; do
        selected="$(prompt_default "Select authentication type" "$default_number")"
        case "$selected" in
            1|ssh) printf '%s' 'ssh'; return ;;
            2|https) printf '%s' 'https'; return ;;
            *) info "Choose 1, 2, ssh, or https." >&2 ;;
        esac
    done
}

choose_auth_type() {
    local default_type="${1:-ssh}"

    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        select_auth_type_arrow "$default_type"
    else
        select_auth_type_numbered "$default_type"
    fi
}

credential_helper_available() {
    local helper="$1"
    local helper_name

    [[ -n "$helper" ]] || return 1
    [[ "$helper" == '!'* || "$helper" == /* ]] && return 0

    helper_name="${helper%% *}"
    command -v "git-credential-${helper_name}" >/dev/null 2>&1 || \
        [[ -x "$(git --exec-path)/git-credential-${helper_name}" ]]
}

find_libsecret_helper() {
    local helper_path

    if command -v git-credential-libsecret >/dev/null 2>&1; then
        command -v git-credential-libsecret
        return
    fi

    helper_path="$(git --exec-path)/git-credential-libsecret"
    if [[ -x "$helper_path" ]]; then
        printf '%s' "$helper_path"
        return
    fi

    if [[ -x "$LIBSECRET_HELPER_PATH" ]]; then
        printf '%s' "$LIBSECRET_HELPER_PATH"
        return
    fi

    return 1
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        info "Root privileges are required, but sudo is not available."
        return 1
    fi
}

install_libsecret_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get install -y git build-essential pkg-config \
            libsecret-1-0 libsecret-1-dev libsecret-tools
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y git gcc make pkgconf-pkg-config \
            libsecret libsecret-devel
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -S --needed --noconfirm git base-devel pkgconf libsecret
    elif command -v zypper >/dev/null 2>&1; then
        run_as_root zypper --non-interactive install git gcc make pkg-config \
            libsecret-devel
    else
        info "Unsupported package manager. Install Git, a C compiler, pkg-config, and libsecret development files manually."
        return 1
    fi
}

find_libsecret_source() {
    local candidate
    local candidates=(
        "/usr/share/doc/git/contrib/credential/libsecret/git-credential-libsecret.c"
        "/usr/share/git-core/contrib/credential/libsecret/git-credential-libsecret.c"
        "/usr/share/git/contrib/credential/libsecret/git-credential-libsecret.c"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done

    find /usr/share -type f -path '*/credential/libsecret/git-credential-libsecret.c' \
        -print -quit 2>/dev/null
}

install_libsecret_helper() {
    local source_file
    local cflags=()
    local libs=()

    if ! command -v cc >/dev/null 2>&1 || \
       ! command -v pkg-config >/dev/null 2>&1 || \
       ! pkg-config --exists libsecret-1 glib-2.0; then
        info "Installing libsecret build requirements..."
        install_libsecret_packages || return 1
    fi

    if ! command -v cc >/dev/null 2>&1 || \
       ! command -v pkg-config >/dev/null 2>&1 || \
       ! pkg-config --exists libsecret-1 glib-2.0; then
        info "The libsecret compiler requirements are still unavailable after package installation."
        return 1
    fi

    source_file="$(find_libsecret_source)"
    if [[ -z "$source_file" ]]; then
        info "Git's git-credential-libsecret source file was not found after package installation."
        info "Install your distribution's Git contrib sources, then run add acc again."
        return 1
    fi

    read -r -a cflags <<<"$(pkg-config --cflags libsecret-1 glib-2.0)"
    read -r -a libs <<<"$(pkg-config --libs libsecret-1 glib-2.0)"
    mkdir -p "$LIBSECRET_INSTALL_DIR"
    chmod 700 "$LIBSECRET_INSTALL_DIR" 2>/dev/null || true

    info "Building git-credential-libsecret..."
    cc -O2 -Wall "${cflags[@]}" "$source_file" -o "$LIBSECRET_HELPER_PATH" "${libs[@]}"
    chmod 700 "$LIBSECRET_HELPER_PATH"
    [[ -x "$LIBSECRET_HELPER_PATH" ]]
}

configure_os_https_credentials() {
    local base_url="$1"
    local auth_username="$2"
    local helper=''
    local libsecret_helper=''

    git config --global "credential.${base_url}.username" "$auth_username"
    git config --global "credential.${base_url}.useHttpPath" true
    helper="$(git config --global --get-all credential.helper 2>/dev/null | tail -n 1 || true)"

    libsecret_helper="$(find_libsecret_helper || true)"
    if [[ -n "$libsecret_helper" ]]; then
        git config --global --unset-all credential.helper 2>/dev/null || true
        git config --global credential.helper "$libsecret_helper"
        info "Using OS-global libsecret credential helper: $libsecret_helper"
        return
    fi

    if credential_helper_available "$helper"; then
        case "$helper" in
            cache*) info "Current OS-global helper '$helper' is temporary; persistent libsecret storage is available as an upgrade." ;;
            store*) info "Current OS-global helper '$helper' stores credentials as plaintext; persistent libsecret storage is recommended." ;;
            *) info "Using OS-global Git credential helper: $helper"; return ;;
        esac
    elif [[ -n "$helper" ]]; then
        info "Warning: OS-global credential helper '$helper' is configured but not available."
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        if confirm "Install persistent libsecret credential storage for this Linux user?" "yes"; then
            if install_libsecret_helper; then
                git config --global --unset-all credential.helper 2>/dev/null || true
                git config --global credential.helper "$LIBSECRET_HELPER_PATH"
                info "Configured OS-global persistent libsecret credential storage."
                info "A running Secret Service/keyring session is required when Git stores or retrieves credentials."
                return
            fi
            info "libsecret installation did not complete."
        fi

        if confirm "Use Git's in-memory credential cache for 8 hours instead?" "yes"; then
            git config --global --unset-all credential.helper 2>/dev/null || true
            git config --global credential.helper 'cache --timeout=28800'
            info "Configured OS-global in-memory credential cache."
        fi
    else
        info "Configure an OS-global credential helper for this operating system if desired."
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
    local auth_type="$2"
    local host_alias="$3"
    local host_name="$4"
    local key_path="$5"
    local auth_username="$6"
    local base_url="$7"
    local user_name="$8"
    local user_email="$9"
    local tmp_file

    tmp_file="$(mktemp)"
    printf '# alias\tauth_type\thost_alias\thost_name\tkey_path\tauth_username\tbase_url\tuser_name\tuser_email\n' >"$tmp_file"
    awk -F '\t' -v alias="$alias" '
        BEGIN { OFS = FS }
        NF && $1 !~ /^#/ && $1 != alias { print }
    ' "$ACCOUNTS_FILE" >>"$tmp_file"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$alias" "$auth_type" "$host_alias" "$host_name" "$key_path" \
        "$auth_username" "$base_url" "$user_name" "$user_email" >>"$tmp_file"
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
        info "Add it to your Git server account."
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
    local i

    ensure_config

    if [[ "$(account_count)" == "0" ]]; then
        info "No accounts saved yet."
        return
    fi

    load_account_menu
    printf '%-20s %-8s %-24s %s\n' "ALIAS" "TYPE" "SERVER" "AUTH"
    for i in "${!ACCOUNT_MENU_ALIASES[@]}"; do
        printf '%-20s %-8s %-24s %s\n' \
            "${ACCOUNT_MENU_ALIASES[$i]}" \
            "${ACCOUNT_MENU_AUTH_TYPES[$i]}" \
            "${ACCOUNT_MENU_HOST_NAMES[$i]}" \
            "${ACCOUNT_MENU_AUTH_DETAILS[$i]}"
    done
}

add_account() {
    local alias="${1:-}"
    local auth_type='ssh' existing_auth_type='ssh'
    local host_alias host_name key_path default_key_path user_name user_email
    local auth_username base_url default_host_alias default_host_name default_key

    ensure_config

    if [[ -z "$alias" ]]; then
        alias="$(prompt_required "Account alias, e.g. personal or company")"
    fi

    validate_alias "$alias"

    if load_account "$alias"; then
        existing_auth_type="$ACCOUNT_AUTH_TYPE"
        info "Account '$alias' already exists."
        confirm "Update it?" "no" || return
    fi

    auth_type="$(choose_auth_type "$existing_auth_type")"
    user_name="$(prompt_required "Git commit user.name for this account")"
    user_email="$(prompt_required "Git commit user.email for this account")"

    validate_tsv_value "Alias" "$alias"
    validate_tsv_value "Git user.name" "$user_name"
    validate_tsv_value "Git user.email" "$user_email"

    if [[ "$auth_type" == "ssh" ]]; then
        default_host_alias="git-${alias}"
        default_host_name="github.com"
        default_key="${SSH_DIR}/id_ed25519_${alias}"

        if [[ "$existing_auth_type" == "ssh" && -n "${ACCOUNT_ALIAS:-}" ]]; then
            default_host_alias="$ACCOUNT_HOST_ALIAS"
            default_host_name="$ACCOUNT_HOST_NAME"
            default_key="$ACCOUNT_KEY_PATH"
        fi

        host_alias="$(prompt_default "SSH host alias" "$default_host_alias")"
        host_name="$(prompt_default "Git host name" "$default_host_name")"
        default_key_path="$default_key"
        key_path="$(prompt_default "SSH key path" "$default_key_path")"
        key_path="$(expand_path "$key_path")"

        validate_tsv_value "SSH host alias" "$host_alias"
        validate_tsv_value "Git host name" "$host_name"
        validate_tsv_value "SSH key path" "$key_path"

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
        save_account "$alias" "ssh" "$host_alias" "$host_name" "$key_path" \
            "git" "-" "$user_name" "$user_email"

        info ""
        info "Saved SSH account '$alias'."
        print_public_key_instructions "$key_path"

        if confirm "Test SSH connection now? Only do this after adding the public key." "no"; then
            ssh -T "git@${host_alias}" || true
        fi
    else
        if [[ "$existing_auth_type" == "https" && -n "${ACCOUNT_ALIAS:-}" ]]; then
            base_url="$(prompt_default "Git server base URL" "$ACCOUNT_BASE_URL")"
            auth_username="$(prompt_default "Git server username" "$ACCOUNT_AUTH_USERNAME")"
        else
            base_url="$(prompt_required "Git server base URL, e.g. https://git.example.com")"
            auth_username="$(prompt_required "Git server username")"
        fi

        base_url="${base_url%/}"
        [[ "$base_url" =~ ^https?://[^/]+(/.*)?$ ]] || die "Git server base URL must start with http:// or https://."
        [[ "$base_url" != *'@'* ]] || die "Do not include username or password in the server URL."
        [[ "$base_url" == https://* ]] || info "Warning: HTTP sends credentials without TLS. HTTPS is strongly recommended."
        host_name="${base_url#*://}"
        host_name="${host_name%%/*}"

        validate_tsv_value "Git server URL" "$base_url"
        validate_tsv_value "Git server username" "$auth_username"

        remove_ssh_block "$alias"
        save_account "$alias" "https" "-" "$host_name" "-" \
            "$auth_username" "$base_url" "$user_name" "$user_email"
        configure_os_https_credentials "$base_url" "$auth_username"

        info ""
        info "Saved HTTPS account '$alias'."
        info "Password was not saved. Git will request it during clone, fetch, pull, or push."
        info "A configured Git credential helper may cache or store it according to that helper's policy."
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

    info "This removes the local multi_git account record for '$alias'."
    confirm "Continue?" "no" || return

    if [[ "$ACCOUNT_AUTH_TYPE" == "ssh" ]]; then
        remove_ssh_block "$alias"
    fi
    delete_account_record "$alias"
    delete_account_repos "$alias"
    info "Removed account '$alias' from multi_git."

    if [[ "$ACCOUNT_AUTH_TYPE" == "ssh" && ( -f "$ACCOUNT_KEY_PATH" || -f "${ACCOUNT_KEY_PATH}.pub" ) ]]; then
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
    local repo_path

    repo_path="$(repo_path_from_input "$input")"
    if [[ "$ACCOUNT_AUTH_TYPE" == "https" ]]; then
        printf '%s/%s.git' "${ACCOUNT_BASE_URL%/}" "$repo_path"
    else
        printf 'git@%s:%s.git' "$ACCOUNT_HOST_ALIAS" "$repo_path"
    fi
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
    git -C "$repo_dir" config --local --unset-all credential.helper 2>/dev/null || true
    git -C "$repo_dir" config --local --unset-all credential.username 2>/dev/null || true
    git -C "$repo_dir" config --local --unset-all credential.useHttpPath 2>/dev/null || true

    if [[ "$ACCOUNT_AUTH_TYPE" == "https" ]]; then
        configure_os_https_credentials "$ACCOUNT_BASE_URL" "$ACCOUNT_AUTH_USERNAME"
    fi

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
    if [[ "$ACCOUNT_AUTH_TYPE" == "https" ]]; then
        info "  HTTPS user: $ACCOUNT_AUTH_USERNAME"
        info "  Credentials: OS-global Git config/credential helper"
    fi
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
    remote_url="$(normalize_repo_remote "$repo_path")"

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
            if [[ "$ACCOUNT_AUTH_TYPE" == "https" ]]; then
                git -c credential.username="$ACCOUNT_AUTH_USERNAME" \
                    -c credential.useHttpPath=true clone "$remote_url" "$destination"
            else
                git clone "$remote_url" "$destination"
            fi
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

clear_main_menu_screen() {
    if [[ -t 0 && -t 2 && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[2J\033[H' >&2
    fi
}

draw_main_menu() {
    local selected="$1"
    local actions=(
        "Add account"
        "Delete account"
        "List accounts"
        "Add or configure repository"
        "Remove current repository configuration"
        "Show current repository"
        "Help and storage details"
        "Quit"
    )
    local i marker

    printf 'multi_git main menu\n' >&2
    printf 'Working directory: %s\n' "$PWD" >&2
    printf 'Use Up/Down and Enter to select.\n\n' >&2

    for i in "${!actions[@]}"; do
        marker=' '
        [[ "$i" -eq "$selected" ]] && marker='>'
        printf ' %s %2s) %s\n' "$marker" "$((i + 1))" "${actions[$i]}" >&2
    done
}

select_main_menu_arrow() {
    local action_names=(
        "add_account"
        "delete_account"
        "list_accounts"
        "add_repo"
        "delete_repo"
        "list_repo"
        "help"
        "quit"
    )
    local selected=0
    local key rest

    clear_main_menu_screen
    draw_main_menu "$selected"

    while IFS= read -rsn1 key; do
        case "$key" in
            '')
                printf '%s\n' "${action_names[$selected]}"
                return
                ;;
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=''
                case "$rest" in
                    '[A')
                        if (( selected > 0 )); then
                            selected=$((selected - 1))
                        else
                            selected=$((${#action_names[@]} - 1))
                        fi
                        ;;
                    '[B')
                        selected=$(((selected + 1) % ${#action_names[@]}))
                        ;;
                esac
                clear_main_menu_screen
                draw_main_menu "$selected"
                ;;
        esac
    done
}

print_main_menu_numbered() {
    printf 'multi_git main menu\n' >&2
    printf 'Working directory: %s\n\n' "$PWD" >&2
    printf '  1. Add account\n' >&2
    printf '  2. Delete account\n' >&2
    printf '  3. List accounts\n' >&2
    printf '  4. Add or configure repository\n' >&2
    printf '  5. Remove current repository configuration\n' >&2
    printf '  6. Show current repository\n' >&2
    printf '  7. Help and storage details\n' >&2
    printf '  8. Quit\n' >&2
}

select_main_menu_numbered() {
    local selected

    print_main_menu_numbered
    while true; do
        selected="$(prompt_required "Select menu number")"
        case "$selected" in
            1) printf '%s' 'add_account'; return ;;
            2) printf '%s' 'delete_account'; return ;;
            3) printf '%s' 'list_accounts'; return ;;
            4) printf '%s' 'add_repo'; return ;;
            5) printf '%s' 'delete_repo'; return ;;
            6) printf '%s' 'list_repo'; return ;;
            7) printf '%s' 'help'; return ;;
            8|q|quit|exit) printf '%s' 'quit'; return ;;
            *) info "Choose a number from 1 to 8." >&2 ;;
        esac
    done
}

choose_main_menu_action() {
    if [[ -t 0 && "${TERM:-dumb}" != "dumb" ]]; then
        select_main_menu_arrow
    else
        select_main_menu_numbered
    fi
}

pause_main_menu() {
    printf '\nPress Enter to return to the main menu...' >&2
    IFS= read -r _menu_pause || true
}

run_main_menu_action() {
    local action="$1"

    case "$action" in
        add_account) add_account ;;
        delete_account) delete_account ;;
        list_accounts) list_accounts ;;
        add_repo) add_repo ;;
        delete_repo) delete_repo ;;
        list_repo) list_repo ;;
        help) usage ;;
        *) die "Unknown menu action: $action" ;;
    esac
}

interactive_main_menu() {
    local action

    ensure_config
    while true; do
        action="$(choose_main_menu_action)"
        if [[ "$action" == "quit" ]]; then
            clear_main_menu_screen
            info "Goodbye."
            return
        fi

        printf '\n' >&2
        if ! (run_main_menu_action "$action"); then
            info "Action failed. Review the message above, then return to the menu." >&2
        fi
        pause_main_menu
    done
}

main() {
    local command="${1:-menu}"
    local target="${2:-}"

    case "$command:$target" in
        menu:*)
            interactive_main_menu
            ;;
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
