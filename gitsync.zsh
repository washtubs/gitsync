#!/usr/bin/env zsh

# TODO: namespace these down

reporoot="$HOME/.master/dev"
repos=( "zshrc" "vimrc" )
gsremote="gsprivate"

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

function _gitsync-repo-sanity() {
    # avoid doing certain things if it does not appear that the repo has gone through setup, or is otherwise wrong
    local repo=$1
    if [ -z "$(git -C $repo remote -v | awk -valias=$gsremote '$1 == alias{print $1}')" ]; then
        echo "$repo: You dont seem to have a private remote set up. run setup for this repo."
        return 1
    fi
}

function _our_git_branch() {
    echo "${machine_id}-dev"
}

function _git_dir() {
    # TODO: refactor with "show-ref --verify --quiet" instead
    # alternatively, replace this function with usage of "rev-parse --git-dir"
    repo=$1
    [ -d $repo/.git ] && { echo $repo/.git; return; }
    [ -f $repo/.git ] && { echo $repo/$(cat $repo/.git | grep "^gitdir:" | sed 's/^gitdir: //'); return; }
    echo "$repo/.git does not appear to be a file or directory." >&2
    
}

_gitsync_checklist=( \
    '$branch_to_track must be *your* branch, not one shared with other people.' \
    '$branch_to_track mast have an upstream at '$gsremote' with the same name.' \
    'gitignores are taken care of... \"git add .\" will be used liberally...' \
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

function _new-files() {
    git -C $1 status --porcelain | awk '$1=="A"||$1=="??"{print $2}'
}

function _auto-wip-on-top() {
    git -C $1 show -s --format=%B $2 | cat | grep --silent "AUTO_WIP"
}

function _gsgit() {
    echo "git $@"
    echo -----
    git $@
    echo -----
}

function _msg() {
    if $_suppress; then
        echo $@ | sed "s|^|${_indent}|" >> $_error_log
    else
        echo $@ | sed "s|^|${_indent}|" >&2
    fi
}

function _branch-has-things-to-push() {
    local repo_dir=$1
    local branch=$2
    # this handles new branch
    git -C $reporoot/$repo_dir rev-parse --verify --quiet $gsremote/$branch >/dev/null || return 0
    _branchA-is-ahead-of-branchB $reporoot/$repo_dir $branch $gsremote/$branch
}

function _branchA-is-ahead-of-branchB() {
    # this is basically checking
    # A: branch contains the merge base with upstream
    # AND
    # B: branch's HEAD isn't *itself* the merge base
    local repo=$1
    local branchA=$2
    local branchB=$3
    { git -C $repo merge-base --is-ancestor $(git -C $repo merge-base $branchA $branchB) $branchA } \
        && [ ! "$(git -C $repo rev-parse $branchA)" = "$(git -C $repo merge-base $branchA $branchB)" ]

}

function _add-and-auto-commit() {
    local repo="$1"
    local branch=$(_current-branch $repo)
    if ! { _is-mine-branch $branch }; then 
        _msg "Not autocommiting you are not on a \"mine\" branch."
        return 1
    fi
    if [ ! -z "$(_new-files $repo)" ]; then
        _msg "New files will be staged:"
        _new-files $repo | cat -n | sed 's/^\s*//' | sed 's/^/    /'
        _verify "Please verify that these are ok and shouldn't be ignored." || \
            return 1
    fi
    git -C $repo add .
    local commit_opts
    commit_opts=()
    _auto-wip-on-top $repo $branch && \
        commit_opts=(--amend --no-edit) || \
        commit_opts=(-m "AUTO_WIP")
    _gsgit -C $repo commit $commit_opts || \
        { _msg "Failed to commit AUTO_WIP"; return 1 }
}

function _push-branch() {
    local repo_dir=$1
    local branch=$2
    #echo "$repo_dir: not doing anything branch $branch"
    #return 0
    if [ ! -z "$(git -C $reporoot/$repo_dir status --porcelain)" ]; then # dirty
        # This is no longer valid: _push-branch is asynchronous typically, and cant handle
        # user interaction of _add-and-auto-commit
        #if [ $(_current-branch $reporoot/$repo_dir) = $ours/$branch ]; then 
            #_add-and-auto-commit $reporoot/$repo_dir || return 1
        #else
        _msg "Your *current* branch is dirty and you are not on $ours/$branch"
        return 1
        #fi
    fi
    if { _branch-has-things-to-push $repo_dir $ours/$branch }; then
        _gsgit -C $reporoot/$repo_dir push --force $gsremote $ours/$branch &>>$_error_log || \
            { _msg "Failed to push $ours/$branch to $gsremote"; return 1 }
    else
        echo "$ours/$branch does not need to be pushed." >> $_error_log
    fi
    if { _branch-has-things-to-push $repo_dir $branch }; then
        _gsgit -C $reporoot/$repo_dir push $gsremote $branch &>>$_error_log || \
            { _msg "Failed to push $branch to $gsremote"; return 1 }
    else
        echo "$branch does not need to be pushed." >> $_error_log
    fi
    return 0
}

function _report-command-async() {
    _async=true
    _message=$1
    shift
    _report-command $@
    unset $_async
    unset $_message
}

function _error-log-has-errors() {
    local last_retry_lineno=0
    if { cat $1 | grep --silent "[RETRY]" }; then
        local last_retry_lineno=$(cat -n $1 | grep "[RETRY]" | tail -n1 | awk '{print $1}')
    fi
    # try to be pretty specific here. We really dont want false positives
    cat $1 | awk -vstart=$last_retry_lineno 'NR>=start{print $0}' | grep -P --silent "(error:|fatal:)"
}

# I'm running into this as an error that should be considered intermittent. It's problematic, because it
# doesn't include a reference to ssh_exchange_identification, ir anything about the connection being screwy
# but that's clearly what is going on because, this happens after retries that get those errors. And trying
# again later usually works. The problem is this error I BELIEVE is indistinguishable from another error
# where the remote url is incorrect. Obviously we don't want to retry in the ladder case.
# Here is the error:
#
#fatal: Could not read from remote repository.

#Please make sure you have the correct access rights
#and the repository exists.
#
# CORRECTION: I believe this can be distinguished by the additional DENIED by fallthru line which indicates
# a misspelling

function _has-fetch-retry-errors() {
    local temp_log=$1
    # should fix above comment
    cat $temp_log | grep -Pv --silent 'DENIED' && \
    cat $temp_log | grep -P --silent "(Connection closed|Connection reset|ssh_exchange_identification|Could not read from remote repository)"
    local result=$?
    rm $temp_log # we DEFINITELY dont need this anymore. yep, for sure
    return $result
}

function _report-command() {
    $@ 
    local success=$?
    # fail as well if the error log has errors, even though the exit code didnt indicate error
    _error-log-has-errors $_error_log && success=1

    local _old_suppress=$_suppress
    if ! $_silent; then
        _suppress=false
    fi
    if $_suppress_iterative; then
        _indent=""
    fi

    if [ ! -z "$(cat $_error_log)" ]; then
        _error_files_present=true
    else
        rm $_error_log
    fi

    if [ $success = 0 ]; then
        local errlog=1
        if $_error_files_present && [ "$gitsync_report_mode" = "always" ]; then
            errlog=0
        else
            rm $_error_log
            _error_files_present=false
        fi
        _report-log-success $errlog
    else
        echo 1 > $_exit_code_file 
        _suppress=false # never suppress errors
        _report-log-fail
    fi

    _suppress=$_old_suppress
}

function _report-log-fail() {
    if ! $_async; then
        $_error_files_present && _msg "Errors occured: $_error_log"
        _msg -e "[$fg[red]FAILED${reset_color}]"
    else
        _msg -e "[$fg[red]FAILED${reset_color}]: $_message -- error log: $_error_log"
    fi
}

function _report-log-success() {
    local errlog=$1
    if ! $_async; then
        _msg -e "[$fg[green]SUCCESS${reset_color}]"
        if [ $errlog = 0 ]; then # yes
            _msg "see log: $_error_log" >&2
        fi
    else
        local suffix=""
        if [ $errlog = 0 ]; then # yes
            suffix=" -- see log: $_error_log"
        fi
        _msg -e "[$fg[green]SUCCESS${reset_color}]": ${_message}${suffix}
    fi
}

function _init() {
}

function _gitsync-finalize() {
    if $_error_files_present; then
        echo
        echo "Please remove any error files when your done with them."
        echo "    rm /tmp/*.gitsyncerrlog"
    fi
    _error_files_present=false
    rm $_exit_code_file
}

function _git-fetch-all() {
    _gsgit -C $1 fetch --all &>>$_error_log
}


function _git-fetch-all-with-retry() {
    local logcheck=$(mktemp "/tmp/gitsyncXXXX")
    _gsgit -C $1 fetch --all &>$logcheck &>>$_error_log
    _has-fetch-retry-errors $logcheck && \
    { echo "[RETRY] failed attempt 1, sleeping 7 seconds" >> $_error_log; sleep 7; 
      _gsgit -C $1 fetch --all &>$logcheck &>>$_error_log } || return 0
    _has-fetch-retry-errors $logcheck && \
    { echo "[RETRY] failed attempt 2, sleeping 14 seconds" >> $_error_log; sleep 14; 
      _gsgit -C $1 fetch --all &>$logcheck &>>$_error_log } || return 0
    _has-fetch-retry-errors $logcheck && \
    { echo "[RETRY] failed attempt 3, sleeping 21 seconds" >> $_error_log; sleep 21; 
      _gsgit -C $1 fetch --all &>$logcheck &>>$_error_log } || return 0
    _has-fetch-retry-errors $logcheck && \
    { echo "[GIVING UP] well this sucks. we tried at least." >> $_error_log; } || return 0
}

function _push-repo-async() {
    push_async="true"
    _push-repo $1
}

# TODO: refactor using show-ref to iterate branches
function _push-repo() {
    _gitsync-repo-sanity $reporoot/$repo_dir || return 1
    local repo_dir=$1
    local ours=$(_our_git_branch)
    local refs=$(_git_dir $reporoot/$repo_dir)/refs/heads/$ours
    local exit_code=0
    if [ ! -e $refs -o ! -d $refs ]; then
        _msg "$refs doesnt exist or is not a directory."
        return 1
    fi
    _indent=""
    for branch in $(find $refs -type f); do
        branch=$(basename $branch)
        _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
        #_suppress=false _msg "pushing $repo_dir @ $ours/$branch ..."
        local oldindent=$_indent
        _indent=${_indent}"    "
        if [ "$push_async" = "true" ]; then
            _report-command-async "pushing $repo_dir @ $ours/$branch" _push-branch $repo_dir $branch &
            [ $? = 0 ] || exit_code=1
            pids=($pids $!)
        else
            _report-command _push-branch $repo_dir $branch
        fi
        _indent=$oldindent
    done
    return $exit_code
}

function _infer-repo-dir() {
    # we MIGHT be a symlink
    local toplevel=$(git rev-parse --show-toplevel)
    if { echo $toplevel | grep --silent -v "^$reporoot" }; then
        # it's a symlink, hopefully its just the $reporoot/$(basename $toplevel)
        candidate_as_symlink=$reporoot/$(basename $toplevel)
        if [ "$(readlink -f $reporoot/$(basename $toplevel))" = $toplevel ]; then
            echo $(basename $toplevel)
        fi
    else
        python2 -c "import os.path; print os.path.relpath('$toplevel', '$reporoot')"
    fi
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
    # TODO: show-ref EVERYWHERE. it disambiguates remotes and heads. and is very well suited to machine interactions.
    # just be wary not to complicate commands that are reported to the user
    res=($(git -C $repo show-ref | awk '{print $2}' | \
        grep -e "^refs/heads/$(_our_git_branch)" -e "^refs/remotes/$gsremote/.*-dev/$ours_branch" | grep -v "^refs/remotes/$gsremote/$(_our_git_branch)" | \
        sed 's/^refs\/\(heads\|remotes\)\///'))
    for candidate in $res; do
        local suffix=""
        _auto-wip-on-top $repo $candidate && suffix="~1"
        if { _branchA-is-ahead-of-branchB $repo ${candidate}${suffix} $ours_branch }; then
            echo ${candidate}${suffix}
        fi
    done
}

function _gitsync-should-merge() {
    local branch=$(_current-branch $reporoot/$(_infer-repo-dir))
    return _is-mine-branch $branch
}

function _checkout-candidates() {
    local repo=$reporoot/$(_infer-repo-dir)
    local search_in=$(_git_dir $repo)/refs/heads/$(_our_git_branch)
    find $search_in -type f -exec python2 -c "import os.path; print os.path.relpath('{}', '$search_in')" \;
}

function _gitsync-can-mount() {
    local repo=$reporoot/$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$(_infer-repo-dir))
    _is-mine-branch $branch && return 1
    if [ -e $(_git_dir $repo)/refs/heads/$(_our_git_branch)/$branch ]; then
        return 1
    else
        return 0
    fi
}

function _gitsync-can-dissolve() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    _auto-wip-on-top $reporoot/$repo_dir $(_current-branch $reporoot/$repo_dir)
}

function _fix-branches() {
    local repo_dir=$1
    local repo=$reporoot/$repo_dir
    local ours=$(_our_git_branch)
    local refs=$repo/.git/refs/heads/$ours
    if [ ! -e $refs -o ! -d $refs ]; then
        _msg "$refs doesnt exist or is not a directory."
        return 1
    fi
    _msg "Run these to make sure your branches aren't screwy."
    _msg
    for branch in $(ls $refs); do
        _msg "git branch $ours/$branch --set-upstream-to=$gsremote/$branch"
    done
}

# TODO account for .git files as directory references, like what _git_dir does
function _get-repos() {
    find $reporoot -path "*/.git/refs/heads/$(_our_git_branch)" -exec python2 -c "import os.path; print os.path.relpath('{}', '$reporoot')" \; | sed 's/\/.git.*//'
}

# P U B L I C
# @public
# {{{

function _gitsync-push-all() {
    pids=()
    _suppress_iterative=true
    _suppress=true
    if [ ! -z "$_gitsync_repos" ]; then
        repos=($_gitsync_repos)
    else
        repos=$(_get-repos)
    fi
    for repo_dir in $repos; do
        _push-repo-async $repo_dir
    done
    wait $pids
}

function _gitsync-fetch-all() {
    pids=()
    _suppress_iterative=true
    _suppress=true
    local ours=$(_our_git_branch)
    if [ ! -z "$_gitsync_repos" ]; then
        repos=($_gitsync_repos)
    else
        repos=$(_get-repos)
    fi
    for repo_dir in $repos; do
        #_suppress=false _msg "Fetching $repo_dir ..."
        _gitsync-fetch $repo_dir &
        pids=($pids $!)
    done
    wait $pids
}

function _gitsync-fetch() {
    local repo_dir=$1
    [ -z $repo_dir ] && repo_dir=$(_infer-repo-dir)
    _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
    #_msg "Fetching $repo_dir ..."
    #_indent="    "
    _report-command-async "fetching $repo_dir" _git-fetch-all-with-retry $reporoot/$repo_dir
}

function gitolite-verify() {
    repo=$1
    if { cat $GITOLITE_ADMIN/conf/gitolite.conf | awk -vrepo=$repo '$1=="repo" && $2==repo{found=1} END{if (found==1){exit 0} else {exit 1}}' }; then
        _msg remote $repo detected.
    else
        _msg remote $repo NOT detected.
        _msg add the following to your $GITOLITE_ADMIN/conf/gitolite.conf, commit, and push
        _msg "repo $repo"
        _msg "    RW+     =   <git.username>"
    fi
    echo ${GITOLITE_ADMIN_PREFIX}${repo}
}

function _verify-gsremote() {
    local repo=$1
    local url
    if [ -z "$(git -C $repo remote -v | awk -valias=$gsremote '$1 == alias{print $1}')" ]; then
        _msg "You don't seem to have a remote set up for $gsremote."
        if [ ! -z $GITOLITE_ADMIN ]; then
            _msg "Would you like us to consult your gitolite admin to ensure that it exists? [y|n]"
            read answer
            if [ $answer = "y" ]; then
                url=$(gitolite-verify $(_infer-repo-dir))
            fi
        fi
    else
        return 0
    fi
    if [ -z $url ]; then
        return 1
    else
        _msg "adding remote alias $gsremote -> $url ..."
        git -C $repo remote add $gsremote $url
        _msg "... and fetching it ..."
        git -C $repo fetch $gsremote
        _msg "You may also need to push your branch."
        _msg "  ex: git push $gsremote master"
        return 0
    fi
}

function _gitsync-setup() {
    local branch_to_track=$1
    local repo=$reporoot/$(_infer-repo-dir)
    local ours=$(_our_git_branch)
    if { _is-mine-branch $branch_to_track } || { git branch | grep --silent " $ours/$branch_to_track$"}; then
        _msg "Branch is already setup..."
        return 0
    fi
    _verify-gsremote $repo || return 1
            
    if [ -z $branch_to_track ]; then
        _msg "You need to supply the name of an existing branch that you want your machine branch to track."
        _msg "gitsync mount master"
        return 1
    fi
    # if one already exists from another branch dont ask
    if ! { git -C $repo branch -vr | grep --silent "^$gsremote" }; then
        _verify-checklist $branch_to_track || return 1
    fi

    git -C $repo branch $ours/$branch_to_track $branch_to_track
    git -C $repo checkout $ours/$branch_to_track
    git -C $repo branch --set-upstream-to=$gsremote/$branch_to_track
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
    # swapping to "ours" triggers a "pull" master merges $gsremote/master
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    _error_log=$(mktemp /tmp/XXXX.gitsyncerrlog)
    if { _is-mine-branch $branch }; then
        if [ ! -z "$(git -C $reporoot/$repo_dir status --porcelain)" ]; then # dirty
            _add-and-auto-commit $reporoot/$repo_dir || return 1
        fi
        _gitsync-checkout-ours
        git merge $gsremote/$(_convert-mine-to-ours $branch)
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
        git merge $(_convert-mine-to-ours $branch)
    else
        _gsgit merge $@
    fi
}

function _gitsync-merge-default() {
    local repo_dir=$(_infer-repo-dir)
    local branch=$(_current-branch $reporoot/$repo_dir)
    if { _is-mine-branch $branch }; then
        _msg "\"mine\" branch not supported"
    else
        local merge_this=$(_convert-ours-to-mine $branch)
        local suffix=""
        _auto-wip-on-top $reporoot/$repo $merge_this && suffix="~1"
        _gsgit merge ${merge_this}${suffix}
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

function _fix-inconsistencies() {
    local repo_dir=$(_infer-repo-dir)
    _verify-gsremote $reporoot/$repo_dir
    _fix-branches $repo_dir
}

# TODO: fetch-all and push-all integration with async
function gitsync() {
    gitsync_report_mode="always" # hard coding this because I'm having trouble dealing with git commands returning zeros when they shouldnt (see: _error-log-has-errors)
    _suppress=false
    _suppress_iterative=false
    _silent=false
    _gitsync-sanity || return
    _error_files_present=false
    _indent=""
    _exit_code_file=$(mktemp /tmp/exitcodeXXXX)
    echo 0 > $_exit_code_file
    action=$1
    exit_code=0
    shift
    case $action in
        push)
            if [ "$1" = "--all" ]; then
                ( _gitsync-push-all )
            else
                _gitsync-push 
            fi
            ;;
        fetch)
            if [ "$1" = "--all" ]; then
                ( _gitsync-fetch-all )
            else
                ( _gitsync-fetch )
            fi
            ;;
        autocommit)
            _gitsync-autocommit
            ;;
        merge)
            _gitsync-merge $@
            ;;
        #merge-default)
            #_gitsync-merge-default
            #;;
        swap)
            _gitsync-swap
            ;;
        checkout)
            _gitsync-checkout $1
            ;;
        mount) #setup
            _gitsync-mount
            ;;
        dissolve)
            _gitsync-dissolve
            ;;
        fix-inconsistencies)
            _fix-inconsistencies
            ;;
    esac
            [[ $(cat $_exit_code_file) = 1 ]] && exit_code=1
    _gitsync-finalize
    return $exit_code
}

#workflow
# when you're done and when you come back ...
# _gitsync-push-all && suspend && _fetch-all && ?merge-public?
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
