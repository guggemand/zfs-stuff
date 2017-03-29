#!/bin/sh
# 
# commands script for openssh authorized_keys
#
# Use this in ~/.ssh/.ssh/authorized_keys
# command="/path/to/authorized_keys_commands.sh",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa .........

set -- $SSH_ORIGINAL_COMMAND

if [ "$1 $2 $3" = "pigz -d |" ]; then
  PIGZ=1
  shift 3
fi

if [ "$1" = "/sbin/zfs" -o "$1" = "zfs" ]; then
  case "$2" in
    "list")
        if [ "$3 $4 $5 $6 $7 $8 $9" = "-t snapshot -s creation -o name -rH" ]; then
          $1 $2 $3 $4 $5 $6 $7 $8 $9 ${10}
          exit $?
        fi
      ;;

    "receive")
        if [ "$3" = "-F" ]; then
          if [ -n "$PIGZ" ]; then
            pigz -d | $1 $2 $3 $4
          else
            $1 $2 $3 $4
          fi
          exit $?
        else
          if [ -n "$PIGZ" ]; then
            pigz -d | $1 $2 $3
          else
            $1 $2 $3
          fi
          exit $?
        fi
      ;;
  esac
fi

echo "'$SSH_ORIGINAL_COMMAND' not allowed"
exit 1

