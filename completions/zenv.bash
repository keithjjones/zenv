# bash completion for zenv.  Installed by install.sh to
# ~/.local/share/bash-completion/completions/zenv, which bash-completion loads
# on demand by filename -- so the file has to be named after the command.
#
# Environment names come from `zenv list --names`, which prints one name per
# line and nothing else. That is the only zenv command this file runs, and it
# reads no metadata itself: a completion that parsed `env` files would be a
# second implementation of the parser, free to disagree with the first.

_zenv() {
    local cur prev cmd i
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    # The subcommand is the first word that is not an option, so `zenv --help`
    # and a future global flag both stay completable.
    cmd=
    for ((i = 1; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            -*) ;;
            *)
                cmd=${COMP_WORDS[i]}
                break
                ;;
        esac
    done

    if [ -z "$cmd" ]; then
        COMPREPLY=($(compgen -W '
            root list ls prefix zkgdir dist status doctor version
            new adopt autoconfig
            init activate deactivate exec shell
            link unlink remove rm
            restore uninstall help
        ' -- "$cur"))
        return
    fi

    # An option's argument, where it is a path rather than a name.
    case $prev in
        --src | --from | --zkg | --root)
            COMPREPLY=($(compgen -d -- "$cur"))
            return
            ;;
        --rc)
            COMPREPLY=($(compgen -f -- "$cur"))
            return
            ;;
    esac

    local names opts=
    names=$(zenv list --names 2>/dev/null)

    case $cmd in
        prefix | zkgdir | dist | status | doctor | activate | autoconfig) ;;
        new) opts='--src' ;;
        adopt) opts='--from --zkg --move --link' ;;
        remove | rm) opts='--keep-zkg --yes --force' ;;
        restore) opts='--dry-run --yes' ;;
        uninstall)
            names=
            opts='--dry-run --purge --yes'
            ;;
        link) ;;
        exec) names="$names -- " ;;
        list | ls)
            names=
            opts='--names'
            ;;
        root)
            names=
            opts='--source'
            ;;
        init)
            names='sh bash zsh'
            ;;
        shell)
            names='activate deactivate'
            ;;
        *) names= ;;
    esac

    case $cur in
        -*) COMPREPLY=($(compgen -W "$opts" -- "$cur")) ;;
        *) COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
    esac
}

complete -F _zenv zenv
