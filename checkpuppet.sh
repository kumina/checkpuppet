#!/bin/sh

### Paths
# The path of the defaults file
DEFAULTS=/etc/default/puppet
# The puppetd pid file
PUPPETFILE=/var/run/puppet/agent.pid
# The state file
STATE=/var/lib/puppet/state/state.yaml
# If we have a pidfile, get the pid
if [ -f $PUPPETFILE ]; then
	PUPPETPID=`cat $PUPPETFILE`
else
	PUPPETPID=1
fi
# The puppetd lock file
LOCKFILE=/var/lib/puppet/state/puppetdlock
# If we have a lock file, get the pid
if [ -f $LOCKFILE ]; then
	LOCKPID=`cat $LOCKFILE`
else
	LOCKPID=1
fi
# Create this file if you don't want puppet to run
DONTRUN=/etc/puppet/dontrunpuppetd
# Create this file if you want puppet to reload
RELOAD=/etc/puppet/reloadpuppetd
# Created when puppet is restarted due to an old state file and removed when it isn't
# old anymore
OLDSTATE=/etc/puppet/oldstate

### Set timers and default actions
# The maximum time (in minutes) a lock file is allowed to exist, if the lock
# file is older the process is killed
MAXLOCK=60
# The time (in seconds) puppet is allowed to use for a stop
MAXSTOPTIME=60
# The maximum age (in minutes) a statefile is allowed to have before puppet is restarted
MAXSTATE=360
# Load custom timers
if [ -f /etc/default/checkpuppet ]; then
	. /etc/default/checkpuppet
fi
# Set to empty to enable debug output, : otherwise
DEBUG=:
# Don't print these messages when reloading
NORELOAD=
# Set to true to remove $PUPPETFILE
RMPUPPET=false
# Set to true to remove $LOCKFILE
RMLOCK=false
# Set to true to start a new puppet
START=false

dumpdebug() {
	[ "$DEBUG" != '' ] && return

	if [ -f $PUPPETFILE ]; then
		PUPPETPID=`cat $PUPPETFILE`
	fi
	if [ -f $LOCKFILE ]; then
		LOCKPID=`cat $LOCKFILE`
	fi
	echo --- Begin debug output ---
	echo Running puppets:
	pgrep puppet || echo "none running"
	if [ "$PUPPETPID" = 1 ]; then echo PUPPETPID = none; else echo PUPPETPID = $PUPPETPID; fi
	if [ "$LOCKPID" = 1 ]; then echo LOCKPID = none; else echo LOCKPID = $LOCKPID; fi
	if [ -f $DONTRUN ]; then echo DONTRUN exists; else echo DONTRUN doesn\'t exist; fi
	if [ -f $RELOAD ]; then echo RELOAD exists; else echo RELOAD doesn\'t exist; fi
	echo --- End debug output ---
}

dumpdebug

removestale() {
	if ! kill -s 0 $1
	then
		rm -f $2
		$DEBUG echo Removed $2 as it has no associated process
	fi
}

removestale $PUPPETPID $PUPPETFILE
removestale $LOCKPID $LOCKFILE

### Set the actions that are to be performed and perform actions on semaphores
# If $1 is "enable" remove the $DONTRUN
if [ "$1" = "enable" ]; then
	rm -f $DONTRUN
	$DEBUG echo Removed $DONTRUN due to enable command
# If $1 is "disable" create the $DONTRUN
elif [ "$1" = "disable" ]; then
	touch $DONTRUN
	$DEBUG echo Created $DONTRUN due to disable command
fi
# If the statefile is too old remove the $PID and start a new puppet, if this hasn't been done before
if [ -f $STATE ] && find $STATE -mmin +$MAXSTATE | fgrep -q $STATE; then
	if [ ! -f $OLDSTATE ]; then
		RMPUPPET=true
		START=true
		touch $OLDSTATE
		$DEBUG echo $STATE is older than $MAXSTATE, PID removal and restart scheduled
	else
		$DEBUG echo $STATE is older than $MAXSTATE, but $OLDSTATE exists
	fi
elif [ -f $OLDSTATE ]; then
	rm -f $OLDSTATE
	$DEBUG echo $STATE is not older than $MAXSTATE, removed $OLDSTATE
fi
# If $DONTRUN exists remove the $PID
if [ -f $DONTRUN ]; then
	RMPUPPET=true
	$DEBUG echo $DONTRUN found, PID removal scheduled
	# If $LOCKFILE expired remove it
	if [ -f $LOCKFILE ] && find $LOCKFILE -mmin +$MAXLOCK | fgrep -q $LOCKFILE; then
		RMLOCK=true
		$DEBUG echo $LOCKFILE is older than $MAXLOCK, lock removal scheduled
	fi
# If $LOCKFILE expired remove everything and restart
elif [ -f $LOCKFILE ] && find $LOCKFILE -mmin +$MAXLOCK | fgrep -q $LOCKFILE; then
	RMPUPPET=true
	RMLOCK=true
	START=true
	$DEBUG echo $LOCKFILE is older than $MAXLOCK, lock and PID removal and restart scheduled
# If $RELOAD exists remove the $PID and start a new puppet
elif [ -f $RELOAD ]; then
	RMPUPPET=true
	START=true
	NORELOAD=:
	rm -f $RELOAD
	$DEBUG echo $RELOAD found, PID removal and restart scheduled
# If $PID doesn't exist start a new puppet
elif [ ! -f $PUPPETFILE ]; then
	START=true
	$DEBUG echo No $PUPPETFILE found, restart scheduled
fi

setstart()
{
	$DEBUG echo Setting START in $DEFAULTS to $1
	sed -i "s/^START=.*/START=$1/" $DEFAULTS
	if ! grep -q '^START=' $DEFAULTS; then
		$DEBUG echo No START found, adding to the file
		cat >> $DEFAULTS << EOF
# Start puppet on boot?
START=$1
EOF
	fi
}

### Performs the needed actions
# Set the value of START in the defaults file
if [ -f $DONTRUN ]; then
	$DEBUG echo $DONTRUN found
	setstart no
else
	$DEBUG echo No $DONTRUN found, START in $DEFAULTS should be yes
	setstart yes
fi
# Remove the $PUPPETFILE if needed
if $RMPUPPET; then
	$DEBUG echo $PUPPETFILE removal is scheduled, deleting $PUPPETFILE
	rm -f $PUPPETFILE
	PUPPETPID=1
fi
# Remove the $LOCKFILE if needed
if $RMLOCK; then
	$DEBUG echo $LOCKFILE removal is scheduled, deleting $LOCKFILE
	rm -f $LOCKFILE
	LOCKPID=1
fi
# Kill all puppetds that are not in the $PID or $LOCK file
for p in `ps ax -o pid,command | awk '/puppet[ ]agent / { print $1 }'`; do
	$DEBUG echo -n "Checking process $p for validity: "
	if [ $p != "$PUPPETPID" -a $p != "$LOCKPID" ]; then
		$NORELOAD echo Killing $p as it is not associated with a pid or lock file.
		$NORELOAD echo PID: $PUPPETPID
		$NORELOAD echo LOCK: $LOCKPID
		$NORELOAD ps up $p
		$NORELOAD ps o ppid $p
		$NORELOAD ps up `ps ho ppid $p`
		kill -9 $p
	else
		$DEBUG echo $p is valid
	fi
done
# Start puppet if needed
if $START; then
	$DEBUG echo Start scheduled, restarting puppet
	# If the restart was not scheduled it should trigger an email
	$NORELOAD echo "Restarting puppet on `hostname -f`!!"
	if [ "$NORELOAD" = '' ]
	then
		/etc/init.d/puppet restart
	else
		/etc/init.d/puppet restart > /dev/null
	fi
fi

dumpdebug
