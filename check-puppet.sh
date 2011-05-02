#!/bin/sh

### Paths
# The path of the defaults file
DEFAULTS=/etc/default/puppet
# The puppetd pid file
PID=/var/run/puppet/puppetd.pid
# The state file
STATE=/var/lib/puppet/state/state.yaml
# If we have a pidfile, get the pid
if [ -f $PID ]; then
	PUPPETPID=`cat $PID`
else
	PUPPETPID=1
fi
# The puppetd lock file
LOCK=/var/lib/puppet/state/puppetdlock
# If we have a lock file, get the pid
if [ -f $LOCK ]; then
	LOCKPID=`cat $LOCK`
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
DEBUG=
# Set to true to remove $LOCK
RMLOCK=false
# Set to true to remove $PID
RMPID=false
# Set to true to start a new puppet
START=false

if [ "$DEBUG" = '' ]; then
	echo --- Original situation ---
	echo Running puppets:
	pgrep puppetd || echo "none running"
	if [ $PUPPETPID = 1 ]; then echo PID = none; else echo PID = $PUPPETPID; fi
	if [ $LOCKPID = 1 ]; then echo LOCK = none; else echo LOCK = $LOCKPID; fi
	if [ -f $DONTRUN ]; then echo DONTRUN exists; else echo DONTRUN doesn\'t exist; fi
	if [ -f $RELOAD ]; then echo RELOAD exists; else echo RELOAD doesn\'t exist; fi
	if [ "$1" = "enable" -o "$1" = "disable" ]; then
		echo Command
		echo $1
	fi
	echo --- Script output ---
fi
	
### Check if the processes in $PID and $LOCK are still valid and if not
### remove the $PID or $LOCK
PIDVALID=false
LOCKVALID=false
for APID in `pgrep puppetd`; do
	$DEBUG echo -n "Checking PID/LOCK association of $APID: "
	if `ps $APID | grep -q puppetd`; then
		if [ $APID = $PUPPETPID -a $APID = $LOCKPID ]; then
			PIDVALID=true
			LOCKVALID=true
			$DEBUG echo $APID is in the PID and LOCK files
		elif [ $APID = $PUPPETPID ]; then
			PIDVALID=true
			$DEBUG echo $APID is in the PID file
		elif [ $APID = $LOCKPID ]; then
			LOCKVALID=true
			$DEBUG echo $APID is in the LOCK file
		else
			$DEBUG echo $APID has no association
		fi
	fi
done
if ! `$PIDVALID` && [ -f $PID ]; then
	rm $PID
	$DEBUG echo Removed PID as it has no associated process
fi
if ! `$LOCKVALID` && [ -f $LOCK ]; then
	rm $LOCK
	$DEBUG echo Removed LOCK as it has no associated process
fi

### Set the actions that are to be performed and perform actions on semaphores
# If $1 is "enable" remove the $DONTRUN
if [ "$1" = "enable" ]; then
	$DEBUG echo Enable command received
	if [ -f $DONTRUN ]; then
		$DEBUG echo $DONTRUN found
		rm $DONTRUN
		$DEBUG echo Removed $DONTRUN due to enable command
	fi
# If $1 is "disable" create the $DONTRUN
elif [ "$1" = "disable" ]; then
	$DEBUG echo Disable command received
	if [ ! -f $DONTRUN ]; then
		$DEBUG echo No $DONTRUN found
		touch $DONTRUN
		$DEBUG echo Created $DONTRUN due to disable command
	fi
fi
# If the statefile is too old remove the $PID and start a new puppet, if this hasn't been done before
if [ -f $STATE ] && `find $STATE -mmin +$MAXSTATE | grep -q $STATE`; then
	if [ ! -f $OLDSTATE ]; then
		RMPID=true
		START=true
		touch $OLDSTATE
		$DEBUG echo $STATE is older than $MAXSTATE, PID removal and restart scheduled
	else
		$DEBUG echo $STATE is older than $MAXSTATE, but $OLDSTATE exists
	fi
elif [ -f $OLDSTATE ]; then
	rm $OLDSTATE
	$DEBUG echo $STATE is not older than $MAXSTATE, removed $OLDSTATE
fi
# If $DONTRUN exists remove the $PID
if [ -f $DONTRUN ]; then
	RMPID=true
	$DEBUG echo $DONTRUN found, PID removal scheduled
	# If $LOCK expired remove it
	if [ -f $LOCK ] && `find $LOCK -mmin +$MAXLOCK | grep -q $LOCK`; then
		RMLOCK=true
		$DEBUG echo $LOCK is older than $MAXLOCK, lock removal scheduled
	fi
# If $LOCK expired remove everything and restart
elif [ -f $LOCK ] && `find $LOCK -mmin +$MAXLOCK | grep -q $LOCK`; then
	RMLOCK=true
	RMPID=true
	START=true
	$DEBUG echo $LOCK is older than $MAXLOCK, lock and PID removal and restart scheduled
# If $RELOAD exists remove the $PID and start a new puppet
elif [ -f $RELOAD ]; then
	RMPID=true
	START=true
	$DEBUG echo $RELOAD found, PID removal and restart scheduled
# If $PID doesn't exist start a new puppet
elif [ ! -f $PID ]; then
	START=true
	$DEBUG echo No $PID found, restart scheduled
fi

### Performs the needed actions
# Set the value of START in the defaults file
if [ -f $DONTRUN ]; then
	$DEBUG echo $DONTRUN found, START in $DEFAULTS should be no
	sed -i 's/^START=yes$/START=no/' $DEFAULTS
	if ! grep -q '^START=no$' $DEFAULTS; then
		$DEBUG echo No START found, adding to $DEFAULTS
		echo "# Start puppet on boot?" >> $DEFAULTS
		echo "START=no" >> $DEFAULTS
	fi
else
	$DEBUG echo No $DONTRUN found, START in $DEFAULTS should be yes
	sed -i 's/^START=no$/START=yes/' $DEFAULTS
	if ! grep -q '^START=yes$' $DEFAULTS; then
		$DEBUG echo No START found, adding it to $DEFAULTS
		echo "# Start puppet on boot?" >> $DEFAULTS
		echo "START=yes" >> $DEFAULTS
	fi
fi
# Remove the $PID if needed
if [ -f $PID ] && `$RMPID`; then
	$DEBUG echo $PID exists and removal is scheduled, deleting $PID
	rm $PID
	PUPPETPID=1
fi
# Remove the $LOCK if needed
if [ -f $LOCK ] && `$RMLOCK`; then
	$DEBUG echo $LOCK exists and removal is scheduled, deleting $LOCK
	rm $LOCK
	LOCKPID=1
fi
# Kill all puppetds that are not in the $PID or $LOCK file
for APID in `pgrep puppetd`; do
	$DEBUG echo -n "Checking process $APID for validity: "
	if [ $APID != $PUPPETPID -a $APID != $LOCKPID ]; then
		echo Killing $APID as it is not associated with a pid or lock file.
		kill -9 $APID
	else
		$DEBUG echo $APID is valid
	fi
done
# Start puppet if needed
if `$START`; then
	$DEBUG echo Start scheduled, restarting puppet
	# If the restart was not scheduled it should trigger an email
	if [ ! -f $RELOAD ]; then
		echo "Restarting puppet on "`hostname -f`"!!"
	fi
	service puppet restart
fi
# Remove $RELOAD if it exists
if [ -f $RELOAD ]; then
	$DEBUG echo $RELOAD found, removing it
	rm $RELOAD
fi
if [ "$DEBUG" = '' ]; then
	if [ -f $PID ]; then
		PUPPETPID=`cat $PID`
	fi
	if [ -f $LOCK ]; then
		LOCKPID=`cat $LOCK`
	fi
	echo --- New situation ---
	echo Running puppets:
	pgrep puppetd || echo "none running"
	if [ $PUPPETPID = 1 ]; then echo PID = none; else echo PID = $PUPPETPID; fi
	if [ $LOCKPID = 1 ]; then echo LOCK = none; else echo LOCK = $LOCKPID; fi
	if [ -f $DONTRUN ]; then echo DONTRUN exists; else echo DONTRUN doesn\'t exist; fi
	if [ -f $RELOAD ]; then echo RELOAD exists; else echo RELOAD doesn\'t exist; fi
fi
