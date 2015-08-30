#!/usr/bin/env zsh

#
# G I T   S Y N C
# @gitsync
# {{{

function _gitsync-sanity() {
    if [ -z $machine_id ];
    then
        echo "gitsync will not load unless you have a machine_id"
        return 1
    fi

    _forbidden_characters="/"
    if { echo $machine_id | grep --silent "[$_forbidden_characters]" }; then
        echo "gitsync has detected that your machine_id $machine_id is pretty stupid."
        echo "actually it probably just has a bad character. These are the characters that aren't allowed: $_forbidden_characters"
        return 1
    fi
}

function _our_git_branch() {
    local ours
    echo "${machine_id}-dev"
}

_gitsync_checklist=( \
    '$branch_to_track must be *your* branch, not one shared with other people.' \
    '$branch_to_track mast have an upstream at origin with the same name.' \
    'gitignores are taken care of... `git add .` will be used liberally...' \
)

function _verify-checklist() {
    _indent=""
    _msg "Please verify these items are all good before starting to track your repo"
    _indent="    "
    local branch_to_track=$1
    local count=1
    for item in $_gitsync_checklist; do
        item="\"$item\""
        item=$(eval echo "$item")
        _msg $count: $item
        ((count++))
    done
    _verify "Ok?"
}

function _verify() {
    local question=$1
    _msg -n "$question [y/n] "
    read answer
    case $answer in
        "y"|"Y") return 0 ;;
        *) return 1 ;;
    esac
}

function _current-branch() {
    git -C $1 rev-parse --abbrev-ref HEAD
}

function _branch-exists() {
    git -C $1 rev-parse --verify $2 &>/dev/null
}

function _new-files-staged() {
    git -C $1 status --porcelain | awk '$1=="A"{print $2}'
}

function _auto-wip-on-top() {
    git -C $1 show -s --format=%B $2 | cat | grep --silent "AUTO_WIP"
}

function _gsgit() {
    echo "git $@"
    echo -----
    git $@
}

function _msg() {
    echo $@ | sed "s|^|${_indent}|" >&2
}

function _branch-has-things-to-push() {
    # this is basically checking
    # A: branch contains the merge base with upstream
    # B: branch's HEAD isn't *itself* the merge base
    local repo_dir=$1
    local branch=$2
    [ ! -z "$(git -C $reporoot/$repo_dir branch $branch --contains $(git -C $reporoot/$repo_dir merge-base $branch origin/$branch) | grep '^\*')" ] \
        && [ ! "$(git -C $reporoot/$repo_dir rev-parse $branch)" = "$(git -C $reporoot/$repo_dir merge-base $branch origin/$branch)" ]
}

function _add-and-auto-commit() {
    local repo="$1"
    local branch=$(_current-branch $repo)
    if ! { _is-mine-branch $branch }; then 
        _msg "Not autocommiting you are not on a \"mine\" branch."
        return 1
    fi
    git -C $repo add .
    if [ ! -z "$(_new-files-staged $repo)" ]; then
        _msg "New files have been staged:"
        _new-files-staged $repo | cat -n | sed 's/^\s*//' | sed 's/^/    /'
        _verify "Please verify that these are ok and shouldn't be ignored." || \
            return 1
    fi
    local commit_opts
    commit_opts=()
    _auto-wip-on-top $repo $branch && \
        commit_opts=(--amend --no-edit) || \
        commit_opts=(-m "AUTO_WIP")
    _gsgit -C $reporoot/$repo_dir commit $commit_opts &>>$_error_log || \
        { _msg "Failed to commit AUTO_WIP"; return 1 }
}

function _push-branch() {
    local repo_dir=$1
    local branch=$2
    if [ ! -z "$(git -C $reporoot/$repo_dir status --porcelain)" ]; then # dirty
        if [ $(_current-branch $reporoot/$repo_dir) = $ours/$branch ]; then 
            _add-and-auto-commit $reporoot/$repo_dir
        else
            _msg "Your *current* branch is dirty and you are not on $ours/$branch"
            return 1
        fi
    fi
    _gsgit -C $reporoot/$repo_dir push --force origin $ours/$branch &>>$_error_log || \
        { _msg "Failed to push $ours/$branch to origin"; return 1 }
    _branch-has-things-to-push $repo_dir $branch &&
        { _gsgit -C $reporoot/$repo_dir push origin $branch &>>$_error_log || \
            { _msg "Failed to push $branch to origin"; return 1 } }
    return 0
}

function _report-command() {
    if { $@ }; then

        # TODO reuse
        if [ ! -z "$(cat $_error_log)" ]; then
            _error_files_present=true
        else
            rm $_error_log
        fi

        _msg -e $fg[green]"[SUCCESS]"$reset_color
        if $_error_files_present && [ "$gitsync_report_mode" = "always" ]; then
            _msg "see log: $_error_log" >&2
        else
            rm $_error_log
            _error_files_present=false
        fi
    else

        if [ ! -z "$(cat $_error_log)" ]; then
            _error_files_present=true
        else
            rm $_error_log
        fi

        $_error_files_present && _msg "Errors occured: $_error_log" >&2
        _msg -e $fg[red]"[FAILED]"$reset_color
    fi
}

function _init() {
    _error_files_present=false
    _indent=""
}

function _finalize() {
    if $_error_files_present; then
        echo
        echo "Please remove any error files when your done with them."
        echo "    rm /tmp/*.gitsyncerrlog"
    fi
    _error_files_present=false
}

function _git-fetch-all() {
    _gsgit -C $1 fetch --all &>$_error_log
}

function _push-repo() {
    local repo_dir=$1
    local ours=$(_our_git_branch)
    local refs=$reporoot/$repo_dir/.git/refs/heads/$ours
    if [ ! -e $refs -o ! -d $refs ]; then
        _msg "$refs doesnt exist or is not a directory."
        return 1
    fi
    _msg "Pushing $repo_dir ..."
    _indent="    "
    for branch in $(ls $refs); do
        _msg "$ours/$branch ..."
        _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
        local oldindent=$_indent
        _indent=${_indent}"    "
        _report-command _push-branch $repo_dir $branch
        _indent=$oldindent
    done
}

function _infer-repo-dir() {
    python2 -c "import os.path; print os.path.relpath('$(git rev-parse --show-toplevel)', '$reporoot')"
}

function _is-mine-branch() {
    test "$(echo $1 | awk -F"/" '{print $1}')" = "$(_our_git_branch)"
}

function _convert-ours-to-mine() {
    echo $(_our_git_branch)/$1
}

function _convert-mine-to-ours() {
    python2 -c "import os.path; print os.path.relpath('$1', '$(_our_git_branch)')"
}

function _merge-candidates() {
    local repo=$1
    local ours_branch=$(_current-branch $repo)
    local search_in
    search_in=( $repo/.git/refs/heads $repo/.git/refs/remotes/ )
    res=($( \
        for root in $search_in; do
            find $root -path "*-dev/$ours_branch" -exec python2 -c "import os.path; print os.path.relpath('{}', '$root')" \;
        done | sort -u | grep -v "origin/$(_our_git_branch)/$ours_branch" \
    ))
    for c in $res; do
        local suffix=""
        _auto-wip-on-top $repo $c && suffix="~1"
        echo ${c}${suffix}
    done
}

function _gitsync-should-merge() {
    local branch=$(_current-branch $reporoot/$(_infer-repo-dir))
    return _is-mine-branch $branch
}

function _checkout-candidates() {
    local repo=$reporoot/$(_infer-repo-dir)
    local search_in=$repo/.git/refs/heads/$(_our_git_branch)
    find $search_in -type f -exec python2 -c "import os.path; print os.path.relpath('{}', '$search_in')" \;
}

function _gitsync-can-mount() {
    local repo=$reporoot/$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$(_infer-repo-dir))
    if [ ! -e $repo/.git/refs/heads/$(_our_git_branch)/$branch ]; then
        return 0
    else
        return 1
    fi
}

function _gitsync-can-dissolve() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    _auto-wip-on-top $reporoot/$repo_dir $(_current-branch $reporoot/$repo_dir)
}

# P U B L I C
# @public
# {{{

reporoot="$DEV"
repos=( "zshrc" "vimrc" )

function _push-all() {
    for repo_dir in $repos; do
        _push-repo $repo_dir
    done
}

function _fetch-all() {
    local ours=$(_our_git_branch)
    for repo_dir in $repos; do
        _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
        _msg "Fetching $repo_dir ..."
        _indent="    "
        _report-command _git-fetch-all $reporoot/$repo_dir
    done
}

function _gitsync-setup() {
    local branch_to_track=$1
    local repo=$reporoot/$(_infer-repo-dir)
    if [ -z $branch_to_track ]; then
        _msg "You need to supply the name of an existing branch that you want your machine branch to track."
        _msg "gitsync mount master"
        return 1
    fi
    local ours=$(_our_git_branch)
    # if one already exists from another branch dont ask
    if ! { _merge-candidates $repo | grep --silent "^origin" }; then
        _verify-checklist $branch_to_track || return 1
    fi

    git -C $repo branch $ours/$branch_to_track $branch_to_track
    git -C $repo checkout $ours/$branch_to_track
    git -C $repo branch --set-upstream-to=origin/$branch_to_track
}

function _gitsync-checkout-ours() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    # confirm branch doesnt start with "ours"
    if ! { _is-mine-branch $branch }; then
        _msg "It appears you are not on a \"mine\" branch"
        return 1
    fi
    local ours_branch=$(_convert-mine-to-ours $branch)
    _msg "$ours_branch"
    git -C $reporoot/$repo_dir checkout $ours_branch 
}

function _gitsync-checkout-mine() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    # confirm branch doesnt start with "ours"
    if { _is-mine-branch $branch }; then
        _msg "It appears you are already on a \"mine\" branch"
        return 1
    fi
    local mine_branch=$(_convert-ours-to-mine $branch)
    git -C $reporoot/$repo_dir checkout $mine_branch
}

function _gitsync-autocommit() {
    local repo_dir=$(_infer-repo-dir)
    _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
    _report-command _add-and-auto-commit $reporoot/$repo_dir 
}

function _gitsync-push() {
    local repo_dir=$(_infer-repo-dir)
    _push-repo $repo_dir
}

function _gitsync-swap() {
    # swapping to "ours" triggers a "pull" master merges origin/master
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    if { _is-mine-branch $branch }; then
        if [ ! -z "$(git -C $reporoot/$repo_dir status --porcelain)" ]; then # dirty
            _add-and-auto-commit $reporoot/$repo_dir
        fi
        _gitsync-checkout-ours
        git merge origin/$(_convert-mine-to-ours $branch)
    else
        if { _branch-exists $reporoot/$repo_dir $(_convert-ours-to-mine $branch) }; then
            _gitsync-checkout-mine
            if { _auto-wip-on-top $reporoot/$repo_dir $(_current-branch $reporoot/$repo_dir) }; then
                git reset HEAD~1
            fi
        else
            _gitsync-setup $branch
        fi
    fi
}

function _gitsync-merge() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    if { _is-mine-branch $branch }; then
        git merge origin/$(_convert-mine-to-ours $branch)
    else
        _gsgit merge $@
    fi
}

function _gitsync-checkout() {
    local checkoutbranch=$1
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    git -C $reporoot/$repo_dir checkout $(_our_git_branch)/$checkoutbranch 
}

function _gitsync-mount() {
    local repo_dir=$(_infer-repo-dir)
    _gitsync-setup $(_current-branch $reporoot/$repo_dir)
}

function _gitsync-dissolve() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    if { _auto-wip-on-top $reporoot/$repo_dir $(_current-branch $reporoot/$repo_dir) }; then
        _gsgit reset HEAD~1
    fi
}

function gitsync() {
    _gitsync-sanity || return
    _init
    action=$1
    shift
    case $action in
        push)
            _gitsync-push $@
            ;;
        autocommit)
            _gitsync-autocommit
            ;;
        merge)
            _gitsync-merge $@
            ;;
        swap)
            _gitsync-swap
            ;;
        checkout)
            _gitsync-checkout $1
            ;;
        mount)
            _gitsync-mount
            ;;
        dissolve)
            _gitsync-dissolve
            ;;
    esac
    _finalize
}

#workflow
# when you're done and when you come back ...
# _push-all && suspend && _fetch-all && ?merge-public?
#
# while working ...
# hack away on mine
# go to ours, merge any of mine or others (defining what is public)
#
# NOTE: you must not merge without help. Always only merge up to the commit before the AUTOCOMMIT if present

# }}}

#function merge-to-master() {

#}

# }}}
