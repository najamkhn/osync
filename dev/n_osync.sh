#!/usr/bin/env bash

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.2-beta3
PROGRAM_BUILD=2016120401
IS_STABLE=no

# Execution order						#__WITH_PARANOIA_DEBUG
#	Function Name				Is parallel	#__WITH_PARANOIA_DEBUG

#	GetLocalOS				no		#__WITH_PARANOIA_DEBUG
#	InitLocalOSDependingSettings		no		#__WITH_PARANOIA_DEBUG
#	CheckEnvironment			no		#__WITH_PARANOIA_DEBUG
#	PreInit					no		#__WITH_PARANOIA_DEBUG
#	Init					no		#__WITH_PARANOIA_DEBUG
#	PostInit				no		#__WITH_PARANOIA_DEBUG
#	GetRemoteOS				no		#__WITH_PARANOIA_DEBUG
#	InitRemoteOSDependingSettings		no		#__WITH_PARANOIA_DEBUG
#	CheckReplicaPaths			yes		#__WITH_PARANOIA_DEBUG
#	CheckDiskSpace				yes		#__WITH_PARANOIA_DEBUG
#	RunBeforeHook				yes		#__WITH_PARANOIA_DEBUG
#	Main					no		#__WITH_PARANOIA_DEBUG
#		CreateStateDirs			yes		#__WITH_PARANOIA_DEBUG
#	 	CheckLocks			yes		#__WITH_PARANOIA_DEBUG
#	 	WriteLockFiles			yes		#__WITH_PARANOIA_DEBUG
#	 	Sync				no		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			deleteList		yes		#__WITH_PARANOIA_DEBUG
#			deleteList		yes		#__WITH_PARANOIA_DEBUG
#			syncAttrs		no		#__WITH_PARANOIA_DEBUG
#			_getFileCtimeMtime	yes		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			deletionPropagation	yes		#__WITH_PARANOIA_DEBUG
#			deletionPropagation	yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#		SoftDelete			yes		#__WITH_PARANOIA_DEBUG
#	RunAfterHook				yes		#__WITH_PARANOIA_DEBUG
#	UnlockReplicas				yes		#__WITH_PARANOIA_DEBUG
#	CleanUp					no		#__WITH_PARANOIA_DEBUG

source "./ofunctions.sh"
_LOGGER_PREFIX="time"

## Working directory. This directory exists in any replica and contains state files, backups, soft deleted files etc
OSYNC_DIR=".osync_workdir"

# The catch CRTL+C behavior can be changed at script entry point with SOFT_STOP=0
function TrapStop {
	if [ $SOFT_STOP -eq 2 ]; then
		Logger " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state." "WARN"
		Logger " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit." "WARN"
		SOFT_STOP=1
		return 1
	fi

	if [ $SOFT_STOP -lt 2 ]; then
		Logger " /!\ WARNING: CTRL+C hit. Exiting osync. Please wait while replicas get unlocked..." "WARN"
		SOFT_STOP=0
		exit 2
	fi
}

function TrapQuit {
	local exitcode

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID" ]; then
		WARN_ALERT=true
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID" ]; then
		ERROR_ALERT=true
	fi

	if [ $ERROR_ALERT == true ]; then
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with errors." "ERROR"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with warnings." "WARN"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=2	# Warning exit code must not force daemon mode to quit
	else
		UnlockReplicas
		RunAfterHook
		Logger "$PROGRAM finished." "ALWAYS"
		exitcode=0
	fi

	CleanUp
	KillChilds $$ > /dev/null 2>&1

	exit $exitcode
}

function CheckEnvironment {
        __CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

        if [ "$REMOTE_OPERATION" == "yes" ]; then
                if ! type ssh > /dev/null 2>&1 ; then
                        Logger "ssh not present. Cannot start sync." "CRITICAL"
                        exit 1
                fi

		if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
			Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
			exit 1
		fi
        fi

        if ! type rsync > /dev/null 2>&1 ; then
                Logger "rsync not present. Sync cannot start." "CRITICAL"
                exit 1
        fi
}

# Only gets checked in config file mode where all values should be present
function CheckCurrentConfig {
        __CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

        # Check all variables that should contain "yes" or "no"
        declare -a yes_no_vars=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
        for i in "${yes_no_vars[@]}"; do
                test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
                eval "$test"
        done

        # Check all variables that should contain a numerical value >= 0
        declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME KEEP_LOGGING MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
        for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
                eval "$test"
        done
}

# Gets checked in quicksync and config file mode
function CheckCurrentConfigAll {
        __CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

	local tmp

        if [ "$INSTANCE_ID" == "" ]; then
                Logger "No INSTANCE_ID defined in config file." "CRITICAL"
                exit 1
        fi

	if [ "$INITIATOR_SYNC_DIR" == "" ]; then
		Logger "No INITIATOR_SYNC_DIR set in config file." "CRITICAL"
		exit 1
	fi

	if [ "$TARGET_SYNC_DIR" == "" ]; then
		Logger "Not TARGET_SYNC_DIR set in config file." "CRITICAL"
		exit 1
	fi

	if [ "$REMOTE_OPERATION" == "yes" ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi

	if [ "$SKIP_DELETION" != "" ]; then
		tmp="$SKIP_DELETION"
		IFS=',' read -r -a SKIP_DELETION <<< "$tmp"
		if [ $(arrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ] && [ $(arrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			Logger "Bogus skip deletion parameter [$SKIP_DELETION]." "CRITICAL"
			exit 1
		fi
	fi
}

###### Osync specific functions (non shared)

function _CheckReplicaPathsLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ ! -w "$replica_path" ]; then
		Logger "Local replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi

	if [ ! -d "$replica_path" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			$COMMAND_SUDO mkdir -p "$replica_path" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
			if [ $? != 0 ]; then
				Logger "Cannot create local replica path [$replica_path]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)"
				exit 1
			else
				Logger "Created local replica path [$replica_path]." "NOTICE"
			fi
		else
			Logger "Local replica path [$replica_path] does not exist." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckReplicaPathsRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ ! -w \"'$replica_path'\" ];then exit 1; fi" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Remote replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_path'\" ]; then if [ \"'$CREATE_DIRS'\" == \"yes\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_path'\"; fi; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot create remote replica path [$replica_path]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

function CheckReplicaPaths {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		if [ "${INITIATOR[$__replicaDir]}" == "${TARGET[$__replicaDir]}" ]; then
			Logger "Initiator and target path [${INITIATOR[$__replicaDir]}] cannot be the same." "CRITICAL"
			exit 1
		fi
	fi

	_CheckReplicaPathsLocal "${INITIATOR[$__replicaDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckReplicaPathsLocal "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	else
		_CheckReplicaPathsRemote "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	if [ $? -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _CheckDiskSpaceLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local diskSpace

	Logger "Checking minimum disk space in [$replica_path]." "NOTICE"

	diskSpace=$($DF_CMD "$replica_path" | tail -1 | awk '{print $4}')

	if [ $? != 0 ]; then
		Logger "Cannot get free space." "ERROR"
	else
		# Ugly fix for df in some busybox environments that can only show human formats
		if [ $(IsInteger $diskSpace) -eq 0 ]; then
			diskSpace=$(HumanToNumeric $diskSpace)
		fi

		if [ $diskSpace -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on replica [$replica_path] ($diskSpace KB)." "WARN"
		fi
	fi
}

function _CheckDiskSpaceRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Checking remote minimum disk space in [$replica_path]." "NOTICE"

	local cmd
	local diskSpace

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "'$COMMAND_SUDO' '$DF_CMD' \"'$replica_path'\"" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot get free space on target [$replica_path]." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		diskSpace=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $4}')

		# Ugly fix for df in some busybox environments that can only show human formats
	        if [ $(IsInteger $diskSpace) -eq 0 ]; then
			diskSpace=$(HumanToNumeric $diskSpace)
		fi

		if [ $diskSpace -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on replica [$replica_path] ($diskSpace KB)." "WARN"
		fi
	fi
}

function CheckDiskSpace {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $MINIMUM_SPACE -eq 0 ]; then
		Logger "Skipped minimum space check." "NOTICE"
		return 0
	fi

	_CheckDiskSpaceLocal "${INITIATOR[$__replicaDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckDiskSpaceLocal "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	else
		_CheckDiskSpaceRemote "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
}


function _CreateStateDirsLocal {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if ! [ -d "$replica_state_dir" ]; then
		$COMMAND_SUDO mkdir -p "$replica_state_dir" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create state dir [$replica_state_dir]." "CRITICAL"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			exit 1
		fi
	fi
}

function _CreateStateDirsRemote {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_state_dir'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_state_dir'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot create remote state dir [$replica_state_dir]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

function CreateStateDirs {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	_CreateStateDirsLocal "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CreateStateDirsLocal "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" &
		pids="$pids;$!"
	else
		_CreateStateDirsRemote "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	if [ $? -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _CheckLocksLocal {
	local lockfile="${1}"
	local replicaType="${2}"

	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local lockfileContent
	local lockPid
	local lockInstanceID

	if [ -s "$lockfile" ]; then
		lockfileContent=$(cat $lockfile)
		Logger "Master lock pid present: $lockfileContent" "DEBUG"
		lockPid=${lockfileContent%@*}
		if [ $(IsInteger $lockPid) -ne 1 ]; then
			Logger "Invalid pid [$lockPid] in local replica." "CRITICAL"
			exit 1
		fi
		lockInstanceID=${lockfileContent#*@}
		if [ "$lockInstanceID" == "" ]; then
			Logger "Invalid instance id [$lockInstanceID] in local replica." "CRITICAL"
			exit 1

		Logger "Local $replicaType  lock is: [$lockPid@$lockInstanceID]." "DEBUG"

		fi
		kill -0 $lockPid > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "There is a local dead osync lock [$lockPid@$lockInstanceID] that is no longer running. Resuming." "NOTICE"
			if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
				# REPLICA_OVERWRITE_LOCK disables noclobber option in WriteLock functions
				INITIATOR_OVERWRITE_LOCK=true
			elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
				TARGET_OVERWRITE_LOCK=true
			fi
		else
			Logger "There is already a local instance [$lockPid@$lockInstanceID] of osync running for this replica. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckLocksRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd
	local lockPid
	local lockInstanceID
	local lockfileContent

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then cat \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'"'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot check remote replica lock." "CRITICAL"
		exit 1
	fi

	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		lockfileContent="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)"

		lockPid=${lockfileContent%@*}
		if [ $(IsInteger $lockPid) -ne 1 ]; then
			Logger "Invalid pid [$lockPid] in remote replica lock." "CRITICAL"
			exit 1
		fi
		lockInstanceID=${lockfileContent#*@}
		if [ "$lockInstanceID" == "" ]; then
			Logger "Invalid instance id [$lockInstanceID] in remote replica." "CRITICAL"
			exit 1
		fi

		Logger "Remote lock is: [$lockPid@$lockInstanceID]" "DEBUG"

		kill -0 $lockPid > /dev/null 2>&1
		if [ $? != 0 ]; then
			if [ "$lockInstanceID" == "$INSTANCE_ID" ]; then
				Logger "There is a remote dead osync lock [$lockPid@lockInstanceID] on target replica that corresponds to this initiator INSTANCE_ID. Pid [$lockPid] no longer running. Resuming." "NOTICE"
				TARGET_OVERWRITE_LOCK=true
			else
				if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]; then
					Logger "There is a remote (maybe dead) osync lock [$lockPid@$lockInstanceID] on target replica that does not correspond to this initiator INSTANCE_ID. Forcing resume." "WARN"
					TARGET_OVERWRITE_LOCK=true
				else
					Logger "There is a remote (maybe dead) osync lock [$lockPid@$lockInstanceID] on target replica that does not correspond to this initiator INSTANCE_ID. Will not resume." "CRITICAL"
					exit 1
				fi
			fi
		else
			Logger "There is already a local instance of osync that locks target replica [$lockPid@$lockInstanceID]. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function CheckLocks {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	# Do not bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK == true ]; then
		WriteLockFiles
		if [ $? != 0 ]; then
			exit 1
		fi
	else
		_CheckLocksLocal "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_CheckLocksLocal "${TARGET[$__lockFile]}" "${INITIATOR[$__type]}" &
			pids="$pids;$!"
		else
			_CheckLocksRemote "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
		if [ $? -ne 0 ]; then
			Logger "Cancelling task." "CRITICAL"
			exit 1
		fi
		WriteLockFiles
	fi
}

function _WriteLockFilesLocal {
	local lockfile="${1}"
	local replicaType="${2}"
	local overwrite="${3:-false}"

	__CheckArguments 2-3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	(
		if [ $overwrite == true ]; then
			set -o noclobber
		fi
		$COMMAND_SUDO echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-$replicaType.$SCRIPT_PID"
	)
	if [ $?	!= 0 ]; then
		Logger "Could not create lock file on local $replicaType in [$lockfile]." "CRITICAL"
		Logger "Command output\n$($RUN_DIR/$PROGRAM.${FUNCNAME[0]}-$replicaType.$SCRIPT_PID)" "NOTICE"
		return 1
	else
		Logger "Locked local $replicaType replica in [$lockfile]." "DEBUG"
	fi
}

function _WriteLockFilesRemote {
	local lockfile="${1}"
	local replicaType="${2}"
	local overwrite="${3-false}"

	__CheckArguments 2-3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "( if [ $overwrite == true ]; then set -o noclobber; fi; echo '$SCRIPT_PID@$INSTANCE_ID' | '$COMMAND_SUDO' tee \"'$lockfile'\")" > /dev/null 2> $RUN_DIR/$PROGRAM._WriteLockFilesRemote.$replicaType.$SCRIPT_PID'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Could not create lock file on remote $replicaType in [$lockfile]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID)" "NOTICE"
		return 1
	else
		Logger "Locked remote $replicaType replica in [$lockfile]." "DEBUG"
	fi
}

function WriteLockFiles {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local initiatorPid
	local targetPid
	local pidArray
	local pid

	_WriteLockFilesLocal "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" $INITIATOR_LOCK_OVERWRITE &
	initiatorPid="$!"

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_WriteLockFilesLocal "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $TARGET_LOCK_OVERWRITE &
		targetPid="$!"
	else
		_WriteLockFilesRemote "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $TARGET_LOCK_OVERWRITE &
		targetPid="$!"
	fi

	INITIATOR_LOCK_FILE_EXISTS=true
	TARGET_LOCK_FILE_EXISTS=true
	WaitForTaskCompletion "$initiatorPid;$targetPid" 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	if [ $? -ne 0 ]; then
		IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
		for pid in "${pidArray[@]}"; do
			pid=${pid%:*}
			if [ "$pid" == "$initiatorPid" ]; then
				INITIATOR_LOCK_FILE_EXISTS=false
			elif [ "$pid" == "$targetPid" ]; then
				TARGET_LOCK_FILE_EXISTS=false
			fi
		done

		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$lockfile" ]; then
		$COMMAND_SUDO rm "$lockfile"
		if [ $? != 0 ]; then
			Logger "Could not unlock local replica." "ERROR"
		else
			Logger "Removed local replica lock." "DEBUG"
		fi
	fi
}

function _UnlockReplicasRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then '$COMMAND_SUDO' rm -f \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Could not unlock remote replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed remote replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	if [ $INITIATOR_LOCK_FILE_EXISTS == true ]; then
		_UnlockReplicasLocal "${INITIATOR[$__lockFile]}" &
		pids="$!"
	fi

	if [ $TARGET_LOCK_FILE_EXISTS == true ]; then
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_UnlockReplicasLocal "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		else
			_UnlockReplicasRemote "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		fi
	fi

	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through weval $rsyncCmd on a remote host.
	## So I am using unescaped $INITIATOR_SYNC_DIR for local rsync calls and escaped $ESC_INITIATOR_SYNC_DIR for remote rsync calls like user@host:$ESC_INITIATOR_SYNC_DIR
	## The same applies for target sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E

function treeList {
	local replicaPath="${1}" # path to the replica for which a tree needs to be constructed
	local replicaType="${2}" # replica type: initiator, target
	local treeFilename="${3}" # filename to output tree (will be prefixed with $replicaType)

	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local escapedReplicaPath
	local rsyncCmd

	escapedReplicaPath=$(EscapeSpaces "$replicaPath")

	# operation explanation
	# (command || :) = Return code 0 regardless of command return code
	# (grep -E \"^-|^d|^l\" || :) = Be sure line begins with '-' or 'd' or 'l' (rsync semantics for file, directory or symlink)
	# (awk '{\$1=\$2=\$3=\$4=\"\" ;print}' || :) = Remove the first four columns of rsync output
	# (awk '{\$1=\$1 ;print}' || :) = Removes leading spaces
	# (awk '{$1=$2=$3=$4="" ;print substr(\$0,5)}' || :) = Same the two lines above, replaces them
	# (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) = Only show output before ' -> ' in order to remove symlink destionations
	# (grep -v \"^\.$\" || :) = Removes line containing current directory sign '.'

	Logger "Creating $replicaType replica file list [$replicaPath]." "NOTICE"
	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escapedReplicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID\" | (grep -E \"^-|^d|^l\" || :) | (awk '{\$1=\$2=\$3=\$4=\"\" ;print substr(\$0,5)}' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID\""
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID\" | (grep -E \"^-|^d|^l\" || :) | (awk '{\$1=\$2=\$3=\$4=\"\" ;print substr(\$0,5)}' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID\""
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID" ]; then
		mv -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType$treeFilename"
	fi

	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) then
		return $?
	elif [ $retval == 23 ]; then
		Logger "Some files could not be listed in $replicaType replica [$replicaPath]. Check for failing symlinks." "ERROR"
		Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID)" "NOTICE"
		return 0
	else
		Logger "Cannot create replica file list in [$replicaPath]." "CRITICAL"
		return $retval
	fi
}

# deleteList(replicaType): Creates a list of files vanished from last run on replica $1 (initiator/target)
function deleteList {
	local replicaType="${1}" # replica type: initiator, target
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	local failedDeletionListFromReplica

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		failedDeletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		failedDeletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	Logger "Creating $replicaType replica deleted file list." "NOTICE"
	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" || :) > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval "$cmd" 2>> "$LOG_FILE"
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" ]; then
			cat "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
			if [ $? == 0 ]; then
				rm -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}"
			else
				Logger "Cannot add failed deleted list to current deleted list for replica [$replicaType]." "ERROR"
			fi
		fi
		return $retval
	else
		touch "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
		return $retval
	fi
}

function _getFileCtimeMtimeLocal {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}" # Initiator / Target
	local fileList="${3}" # Contains list of files to get time attrs
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	echo -n "" > "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID"
	while read -r file; do $STAT_CTIME_MTIME_CMD "$replicaPath$file" | sort >> "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID"; done < "$fileList"
	if [ $? != 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID)" "VERBOSE"
		fi
		exit 1
	fi

}

function _getFileCtimeMtimeRemote {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}"
	local fileList="${3}"
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	cmd='cat "'$fileList'" | '$SSH_CMD' "while read -r file; do '$REMOTE_STAT_CTIME_MTIME_CMD' \"'$replicaPath'\$file\"; done | sort" > "'$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID'"'
	Logger "CMD: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID)" "VERBOSE"
		fi
		exit 1
	fi
}

# rsync does sync with mtime, but file attribute modifications only change ctime.
# Hence, detect newer ctime on the replica that gets updated first with CONFLICT_PREVALANCE and update all newer file attributes on this replica before real update
function syncAttrs {
	local initiatorReplica="${1}"
	local targetReplica="${2}"
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local destDir
	local escSourceDir
	local escDestDir
	local destReplica

	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ]; then
		Logger "Skipping acl synchronization. Busybox does not have join command." "NOTICE"
		return 0
	fi

	Logger "Getting list of files that need updates." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" $REMOTE_USER@$REMOTE_HOST:\"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" \"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Getting list of files that need updates failed [$retval]. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
		fi
		( grep -Ev "^[^ ]*(c|s|t)[^ ]* " "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" || :) | ( grep -E "^[^ ]*(p|o|g|a)[^ ]* " || :) | sed -e 's/^[^ ]* //' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"
		if [ $? != 0 ]; then
			Logger "Cannot prepare file list for attribute sync." "CRITICAL"
			exit 1
		fi
	fi

	Logger "Getting ctimes for pending files on initiator." "NOTICE"
	_getFileCtimeMtimeLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
	pids="$!"

	Logger "Getting ctimes for pending files on target." "NOTICE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_getFileCtimeMtimeLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
		pids="$pids;$!"
	else
		_getFileCtimeMtimeRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}

	# If target gets updated first, then sync_attr must update initiators attrs first
	# For join, remove leading replica paths

	sed -i'.tmp' "s;^${INITIATOR[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID"
	sed -i'.tmp' "s;^${TARGET[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID"

	if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destDir="${TARGET[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destReplica="${TARGET[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	else
		sourceDir="${TARGET[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destDir="${INITIATOR[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destReplica="${INITIATOR[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	fi

	if [ $(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID") -eq 0 ]; then
		Logger "Updating file attributes on $destReplica not required" "NOTICE"
		return 0
	fi

	Logger "Updating file attributes on $destReplica." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost

		# No rsync args (hence no -r) because files are selected with --from-file
		if [ "$destReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"

	fi

	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating file attributes on $destReplica [$retval]. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID)" "VERBOSE"
		fi
		Logger "Successfully updated file attributes on $destReplica replica." "NOTICE"
	fi
}

# syncUpdate(source replica, destination replica, delete_list_filename)
function syncUpdate {
	local sourceReplica="${1}" # Contains replica type of source: initiator, target
	local destinationReplica="${2}" # Contains replica type of destination: initiator, target
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local escSourceDir
	local destDir
	local escDestDir

	local backupArgs

	Logger "Updating $destinationReplica replica." "NOTICE"
	if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		destDir="${TARGET[$__replicaDir]}"
		backupArgs="$TARGET_BACKUP"

		escSourceDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		escDestDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
	else
		sourceDir="${TARGET[$__replicaDir]}"
		destDir="${INITIATOR[$__replicaDir]}"
		backupArgs="$INITIATOR_BACKUP"

		escSourceDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		escDestDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
	fi

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating $destinationReplica replica failed. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID)" "VERBOSE"
		fi
		Logger "Updating $destinationReplica replica succeded." "NOTICE"
		return 0
	fi
}

function _deleteLocal {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local parentdir
	local previousFile=""
	local result

	local deletionListFromReplica

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		deletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		deletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	if [ ! -d "$replicaDir$deletionDir" ] && [ $_DRYRUN == false ]; then
		$COMMAND_SUDO mkdir -p "$replicaDir$deletionDir"
		if [ $? != 0 ]; then
			Logger "Cannot create local replica deletion directory in [$replicaDir$deletionDir]." "ERROR"
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$deletionDir/$files" ] || [ -L "$replicaDir$deletionDir/$files" ]; then
						rm -rf "${replicaDir:?}$deletionDir/$files"
					fi

					if [ -e "$replicaDir$files" ] || [ -L "$replicaDir$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							mkdir -p "$replicaDir$deletionDir/$parentdir"
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir/$parentdir]." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir/$parentdir"
						else
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir]." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move [$replicaDir$files] to deletion directory." "ERROR"
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$files" ] || [ -L "$replicaDir$files" ]; then
						rm -rf "$replicaDir$files"
						result=$?
						Logger "Deleting [$replicaDir$files]." "VERBOSE"
						if [ $result != 0 ]; then
							Logger "Cannot delete [$replicaDir$files]." "ERROR"
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID"
						fi
					fi
				fi
			fi
			previousFile="$files"
		fi
	done < "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}"
}

function _deleteRemote {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local escDestDir
	local rsyncCmd

	local failedDeleteList
	local successDeleteList

	local deletionListFromReplica

	local loggerPrefix

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		deletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		deletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	failedDeleteList="$(EscapeSpaces ${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]})"
	successDeleteList="$(EscapeSpaces ${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]})"

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	escDestDir="$(EscapeSpaces "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}")"
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir/\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID" ]; then
			Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID)" "ERROR"
		fi
		exit 1
	fi

$SSH_CMD ERROR_ALERT=0 sync_on_changes=$sync_on_changes _DEBUG=$_DEBUG _DRYRUN=$_DRYRUN _LOGGER_VERBOSE=$_LOGGER_VERBOSE COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}")" REPLICA_DIR="$(EscapeSpaces "$replicaDir")" SOFT_DELETE=$SOFT_DELETE DELETION_DIR="$(EscapeSpaces "$deletionDir")" FAILED_DELETE_LIST="$failedDeleteList" SUCCESS_DELETE_LIST="$successDeleteList" 'bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" 2>&1

	## The following lines are executed remotely
	function _logger {
		local value="${1}" # What to log
		echo -e "$value"
	}

	function Logger {
		local value="${1}" # What to log
		local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

		local prefix="RTIME: $SECONDS - "

		if [ "$level" == "CRITICAL" ]; then
			_logger "$prefix\e[41m$value\e[0m"
			return
		elif [ "$level" == "ERROR" ]; then
			_logger "$prefix\e[91m$value\e[0m"
			return
		elif [ "$level" == "WARN" ]; then
			_logger "$prefix\e[93m$value\e[0m"
			return
		elif [ "$level" == "NOTICE" ]; then
			_logger "$prefix$value"
			return
		elif [ "$level" == "VERBOSE" ]; then
			if [ $_LOGGER_VERBOSE == true ]; then
				_logger "$prefix$value"
			fi
			return
		elif [ "$level" == "DEBUG" ]; then
			if [ "$_DEBUG" == "yes" ]; then
				_logger "$prefix$value"
			fi
			return
		else
			_logger "\e[41mLogger function called without proper loglevel [$level].\e[0m"
			_logger "$prefix$value"
		fi
	}

	## Empty earlier failed delete list
	> "$FAILED_DELETE_LIST"
	> "$SUCCESS_DELETE_LIST"

	parentdir=
	previousFile=""

	if [ ! -d "$REPLICA_DIR$DELETION_DIR" ] && [ $_DRYRUN == false ]; then
		$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETION_DIR"
		if [ $? != 0 ]; then
			Logger "Cannot create remote replica deletion directory in [$REPLICA_DIR$DELETION_DIR]." "ERROR"
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$DELETION_DIR/$files" ] || [ -L "$REPLICA_DIR$DELETION_DIR/$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$DELETION_DIR/$files"
					fi

					if [ -e "$REPLICA_DIR$files" ] || [ -L "$REPLICA_DIR$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							Logger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR/$parentdir]." "VERBOSE"
							$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETION_DIR/$parentdir"
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR/$parentdir"
						else
							Logger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR]." "VERBOSE"
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move [$REPLICA_DIR$files] to deletion directory." "ERROR"
							# Using $files instead of $REPLICA_DIR$files here so the list is ready for next run
							echo "$files" >> "$FAILED_DELETE_LIST"
						else
							echo "$files" >> "$SUCCESS_DELETE_LIST"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$files" ] || [ -e "$REPLICA_DIR$files" ]; then
						Logger "Deleting [$REPLICA_DIR$files]." "VERBOSE"
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
						if [ $? != 0 ]; then
							Logger "Cannot delete [$REPLICA_DIR$files]." "ERROR"
							echo "$files" >> "$FAILED_DELETE_LIST"
						else
							echo "$files" >> "$SUCCESS_DELETE_LIST"
						fi
					fi
				fi
			fi
			previousFile="$files"
		fi
	done < "$FILE_LIST"
ENDSSH

	if [ -z "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" ]; then
		loggerPrefix="$_LOGGER_PREFIX"
		_LOGGER_PREFIX=""
		Logger "$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID)" "ERROR"
		_LOGGER_PREFIX="$loggerPrefix"
	fi

	## Copy back the deleted failed file list
	#rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"{$failedDeleteList,$successDeleteList}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID\""
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) -r --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" --include \"$(dirname ${TARGET[$__stateDir]})\" --include \"${TARGET[$__stateDir]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]}\" --exclude='*' $REMOTE_USER@$REMOTE_HOST:\"$(EscapeSpaces ${TARGET[$__replicaDir]})\" \"${INITIATOR[$__replicaDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID\""
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	result=$?
	if [ $result != 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID" ]; then
			Logger "Comand output: $(cat $RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi
	return 0
}

# delete_Propagation(replica type)
function deletionPropagation {
	local replicaType="${1}" # Contains replica type: initiator, target where to delete
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local replicaDir
	local deleteDir

	Logger "Propagating deletions to $replicaType replica." "NOTICE"

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		if [ $(arrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${INITIATOR[$__replicaDir]}"
			deleteDir="${INITIATOR[$__deleteDir]}"

			_deleteLocal "${INITIATOR[$__type]}" "$replicaDir" "$deleteDir"
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Deletion on $replicaType replica failed." "CRITICAL"
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		if [ $(arrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${TARGET[$__replicaDir]}"
			deleteDir="${TARGET[$__deleteDir]}"

			if [ "$REMOTE_OPERATION" == "yes" ]; then
				_deleteRemote "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			else
				_deleteLocal "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			fi
			retval=$?
			if [ $retval == 0 ]; then
				if [ -f "$RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID)" "VERBOSE"
				fi
				return $retval
			else
				Logger "Deletion on $replicaType failed." "CRITICAL"
				if [ -f "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID)" "CRITICAL"
				fi
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	fi
}

###### Sync function in 6 steps
######
###### Step 0a & 0b: Create current file list of replicas
###### Step 1a & 1b: Create deleted file list of replicas
###### Step 3: Update file attributes
###### Step 3a & 3b: Update replicas
###### Step 4a & 4b: Propagate deletions on replicas
###### Step 5a & 5b: Create after run file list of replicas

function Sync {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local resumeCount
	local resumeInitiator
	local resumeTarget

	local initiatorPid
	local targetPid

	local initiatorFail
	local targetFail

	Logger "Starting synchronization task." "NOTICE"

	if [ "$RESUME_SYNC" != "no" ]; then
		if [ -f "${INITIATOR[$__resumeCount]}" ]; then
			resumeCount=$(cat "${INITIATOR[$__resumeCount]}")
		else
			resumeCount=0
		fi

		if [ $resumeCount -lt $RESUME_TRY ]; then
			if [ -f "${INITIATOR[$__initiatorLastActionFile]}" ]; then
				resumeInitiator=$(cat "${INITIATOR[$__initiatorLastActionFile]}")
			else
				resumeInitiator="synced"
			fi

			if [ -f "${INITIATOR[$__targetLastActionFile]}" ]; then
				resumeTarget=$(cat "${INITIATOR[$__targetLastActionFile]}")
			else
				resumeTarget="synced"
			fi

			if [ "$resumeInitiator" != "synced" ]; then
				Logger "WARNING: Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__initiatorLastActionFile]}") at task [$resumeInitiator] for initiator. [$resumeCount] previous tries." "WARN"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeInitiator="none"
			fi

			if [ "$resumeTarget" != "synced" ]; then
				Logger "WARNING: Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__targetLastActionFile]}") as task [$resumeTarget] for target. [$resumeCount] previous tries." "WARN"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeTarget="none"
			fi
		else
			Logger "Will not resume aborted execution. Too many resume tries [$resumeCount]." "WARN"
			echo "0" > "${INITIATOR[$__resumeCount]}"
			resumeInitiator="none"
			resumeTarget="none"
		fi
	else
		resumeInitiator="none"
		resumeTarget="none"
	fi


	################################################################################################################################################# Actual sync begins here

	## Step 0a & 0b
	if [ "$resumeInitiator" == "none" ] || [ "$resumeTarget" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
		if [ "$resumeInitiator" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__treeCurrentFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "none" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__treeCurrentFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[0]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[0]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

		 	exit 1
		else
			echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[1]}"
			resumeTarget="${SYNC_ACTION[1]}"
		fi
	fi

	## Step 1a & 1b
	if [ "$resumeInitiator" == "${SYNC_ACTION[1]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[1]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[1]}" ]; then
			deleteList "${INITIATOR[$__type]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[1]}" ]; then
			deleteList "${TARGET[$__type]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

		 	exit 1
		else
			echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[2]}"
			resumeTarget="${SYNC_ACTION[2]}"
		fi
	fi

	## Step 2
	if [ "$resumeInitiator" == "${SYNC_ACTION[2]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
		if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]]; then
			syncAttrs "${INITIATOR[$__replicaDir]}" "$TARGET_SYNC_DIR"
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
				exit 1
			else
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
				resumeInitiator="${SYNC_ACTION[3]}"
				resumeTarget="${SYNC_ACTION[3]}"

			fi
		else
			echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[3]}"
			resumeTarget="${SYNC_ACTION[3]}"
		fi
	fi

	## Step 3a & 3b
	if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
		if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
			if [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}" &
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[3]}"
					exit 1
				else
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[4]}"
				fi
			fi
			if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}"
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[3]}"
					exit 1
				else
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[4]}"
				fi
			fi
		else
			if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}"
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[3]}"
					exit 1
				else
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[4]}"
				fi
			fi
			if [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}"
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[3]}"
					exit 1
				else
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[4]}"
				fi
			fi
		fi
	fi

	## Step 4a & 4b
	if [ "$resumeInitiator" == "${SYNC_ACTION[4]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[4]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[4]}" ]; then
			deletionPropagation "${INITIATOR[$__type]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[4]}" ]; then
			deletionPropagation "${TARGET[$__type]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

		 	exit 1
		else
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[5]}"
			resumeTarget="${SYNC_ACTION[5]}"

		fi
	fi

	## Step 5a & 5b
	if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__treeAfterFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__treeAfterFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

		 	exit 1
		else
			echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[6]}"
			resumeTarget="${SYNC_ACTION[6]}"
		fi
	fi

	Logger "Finished synchronization task." "NOTICE"
	echo "0" > "${INITIATOR[$__resumeCount]}"
}

function _SoftDeleteLocal {
	local replicaType="${1}" # replica type (initiator, target)
	local replicaDeletionPath="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local changeTime="${3}" # Delete files older than changeTime days
	local deletionType="${4}" # Trivial deletion type string

	__CheckArguments 4 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ]; then
		Logger "Skipping $deletionType deletion on $replicaType. Busybox find -ctime not supported." "NOTICE"
		return 0
	fi

	if [ -d "$replicaDeletionPath" ]; then
		if [ $_DRYRUN == true ]; then
			Logger "Listing files older than $changeTime days on $replicaType replica for $deletionType deletion. Does not remove anything." "NOTICE"
		else
			Logger "Removing files older than $changeTime days on $replicaType replica for $deletionType deletion." "NOTICE"
		fi

		if [ $_LOGGER_VERBOSE == true ]; then
			# Cannot launch log function from xargs, ugly hack
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type f -ctime +$changeTime -print0 | xargs -0 -I {} echo "Will delete file {}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type d -empty -ctime +$changeTime -print0 | xargs -0 -I {} echo "Will delete directory {}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
		fi

		if [ $_DRYRUN == false ]; then
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type f -ctime +$changeTime -print0 | xargs -0 -I {} $COMMAND_SUDO rm -f "{}" && $COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type d -empty -ctime +$changeTime -print0 | xargs -0 -I {} $COMMAND_SUDO rm -rf "{}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		else
			Dummy
		fi
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on $replicaType replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on $replicaType replica." "NOTICE"
		fi
	elif [ -d "$replicaDeletionPath" ] && ! [ -w "$replicaDeletionPath" ]; then
		Logger "The $replicaType replica dir [$replicaDeletionPath] is not writable. Cannot clean old files." "ERROR"
	else
		Logger "The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files." "VERBOSE"
	fi
}

function _SoftDeleteRemote {
	local replicaType="${1}"
	local replicaDeletionPath="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local changeTime="${3}" # Delete files older than changeTime days
	local deletionType="${4}" # Trivial deletion type string

	__CheckArguments 4 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ]; then
		Logger "Skipping $deletionType deletion on $replicaType. Busybox find -ctime not supported." "NOTICE"
		return 0
	fi

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ $_DRYRUN == true ]; then
		Logger "Listing files older than $changeTime days on $replicaType replica for $deletionType deletion. Does not remove anything." "NOTICE"
	else
		Logger "Removing files older than $changeTime days on $replicaType replica for $deletionType deletion." "NOTICE"
	fi

	if [ $_LOGGER_VERBOSE == true ]; then
		# Cannot launch log function from xargs, ugly hack
		cmd=$SSH_CMD' "if [ -d \"'$replicaDeletionPath'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type f -ctime +'$changeTime' -print0 | xargs -0 -I {} echo Will delete file {} && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type d -empty -ctime '$changeTime' -print0 | xargs -0 -I {} echo Will delete directory {}; else echo \"The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files.\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
	fi

	if [ $_DRYRUN == false ]; then
		cmd=$SSH_CMD' "if [ -d \"'$replicaDeletionPath'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type f -ctime +'$changeTime' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -f \"{}\" && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type d -empty -ctime '$changeTime' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -rf \"{}\"; else echo \"The $replicaType replicaDir [$replicaDeletionPath] does not exist. Skipping cleaning of old files.\"; fi" >> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'

		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd"
	else
		Dummy
	fi
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote $replicaType replica." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Cleanup complete on $replicaType replica." "NOTICE"
	fi
}

function SoftDelete {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			pids="$pids;$!"
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			pids="$pids;$!"
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
		if [ $? != 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
	fi
}

function _SummaryFromFile {
	local replicaPath="${1}"
	local summaryFile="${2}"
	local direction="${3}"

	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$summaryFile" ]; then
		while read -r file; do
			Logger "$direction $replicaPath$(echo $file | awk '{for (i=2; i<NF; i++) printf $i " "; print $NF}')" "ALWAYS"
		done < "$summaryFile"
	fi
}

function Summary {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local loggerPrefix

	loggerPrefix="$_LOGGER_PREFIX"
	_LOGGER_PREFIX=""

	Logger "Attrib updates: INITIATOR << >> TARGET" "ALWAYS"

	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.target.$SCRIPT_PID" "~ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.initiator.$SCRIPT_PID" "~ <<"

	Logger "File transfers: INITIATOR << >> TARGET" "ALWAYS"
	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.target.$SCRIPT_PID" "+ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.initiator.$SCRIPT_PID" "+ <<"

	Logger "File deletions: INITIATOR << >> TARGET" "ALWAYS"
	if [ "$REMOTE_OPERATION" == "yes" ]; then
		_SummaryFromFile "${TARGET[$__replicaDir]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/target${TARGET[$__successDeletedListFile]}" "- >>"
	else
		_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.target.$SCRIPT_PID" "- >>"
	fi
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.initiator.$SCRIPT_PID" "- <<"

	_LOGGER_PREFIX="$loggerPrefix"
}

function Init {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $sync_on_changes == false ]; then
		trap TrapStop INT HUP TERM QUIT
		trap TrapQuit EXIT
	else
		trap TrapQuit TERM EXIT HUP QUIT
	fi

	local uri
	local hosturiandpath
	local hosturi


	## Test if target dir is a ssh uri, and if yes, break it down it its values
	if [ "${TARGET_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_OPERATION="yes"

		# remove leadng 'ssh://'
		uri=${TARGET_SYNC_DIR#ssh://*}
		if [[ "$uri" == *"@"* ]]; then
			# remove everything after '@'
			REMOTE_USER=${uri%@*}
		else
			REMOTE_USER=$LOCAL_USER
		fi

		if [ "$SSH_RSA_PRIVATE_KEY" == "" ]; then
			if [ ! -f "$SSH_PASSWORD_FILE" ]; then
				# Assume that there might exist a standard rsa key
				SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
			fi
		fi

		# remove everything before '@'
		hosturiandpath=${uri#*@}
		# remove everything after first '/'
		hosturi=${hosturiandpath%%/*}
		if [[ "$hosturi" == *":"* ]]; then
			REMOTE_PORT=${hosturi##*:}
		else
			REMOTE_PORT=22
		fi
		REMOTE_HOST=${hosturi%%:*}

		# remove everything before first '/'
		TARGET_SYNC_DIR=${hosturiandpath#*/}
	else
		REMOTE_OPERATION="no"
	fi

	if [ "$INITIATOR_SYNC_DIR" == "" ] || [ "$TARGET_SYNC_DIR" == "" ]; then
		Logger "Initiator or target path empty." "CRITICAL"
		exit 1
	fi

	## Make sure there is only one trailing slash on path
	INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR%/}/"
	TARGET_SYNC_DIR="${TARGET_SYNC_DIR%/}/"

        # Expand ~ if exists
        INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR/#\~/$HOME}"
        TARGET_SYNC_DIR="${TARGET_SYNC_DIR/#\~/$HOME}"
        SSH_RSA_PRIVATE_KEY="${SSH_RSA_PRIVATE_KEY/#\~/$HOME}"
	SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE/#\~/$HOME}"

	## Replica format
	## Why the f*** does bash not have simple objects ?
	# Local variables used for state filenames
	local lockFilename="lock"
	local stateDir="state"
	local backupDir="backup"
	local deleteDir="deleted"
	local partialDir="_partial"
	local lastAction="last-action"
       	local resumeCount="resume-count"
	if [ "$_DRYRUN" == true ]; then
       		local drySuffix="-dry"
	else
		local drySuffix=
	fi

	# The following associative like array definitions are used for bash ver < 4 compat
	readonly __type=0
	readonly __replicaDir=1
	readonly __lockFile=2
	readonly __stateDir=3
	readonly __backupDir=4
	readonly __deleteDir=5
	readonly __partialDir=6
	readonly __initiatorLastActionFile=7
	readonly __targetLastActionFile=8
	readonly __resumeCount=9
	readonly __treeCurrentFile=10
	readonly __treeAfterFile=11
	readonly __treeAfterFileNoSuffix=12
	readonly __deletedListFile=13
	readonly __failedDeletedListFile=14
	readonly __successDeletedListFile=15

	INITIATOR=()
	INITIATOR[$__type]='initiator'
	INITIATOR[$__replicaDir]="$INITIATOR_SYNC_DIR"
	INITIATOR[$__lockFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$lockFilename"
	INITIATOR[$__stateDir]="$OSYNC_DIR/$stateDir"
	INITIATOR[$__backupDir]="$OSYNC_DIR/$backupDir"
	INITIATOR[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	INITIATOR[$__partialDir]="$OSYNC_DIR/$partialDir"
	INITIATOR[$__initiatorLastActionFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/initiator-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__targetLastActionFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/target-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__resumeCount]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/$resumeCount-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeCurrentFile]="-tree-current-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeAfterFile]="-tree-after-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeAfterFileNoSuffix]="-tree-after-$INSTANCE_ID"
	INITIATOR[$__deletedListFile]="-deleted-list-$INSTANCE_ID$drySuffix"
	INITIATOR[$__failedDeletedListFile]="-failed-delete-$INSTANCE_ID$drySuffix"
	INITIATOR[$__successDeletedListFile]="-success-delete-$INSTANCE_ID$drySuffix"

	TARGET=()
	TARGET[$__type]='target'
	TARGET[$__replicaDir]="$TARGET_SYNC_DIR"
	TARGET[$__lockFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$lockFilename"
	TARGET[$__stateDir]="$OSYNC_DIR/$stateDir"
	TARGET[$__backupDir]="$OSYNC_DIR/$backupDir"
	TARGET[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	TARGET[$__partialDir]="$OSYNC_DIR/$partialDir"											# unused
	TARGET[$__initiatorLastActionFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/initiator-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__targetLastActionFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/target-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__resumeCount]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/$resumeCount-$INSTANCE_ID$drySuffix"				# unused
	TARGET[$__treeCurrentFile]="-tree-current-$INSTANCE_ID$drySuffix"								# unused
	TARGET[$__treeAfterFile]="-tree-after-$INSTANCE_ID$drySuffix"									# unused
	TARGET[$__treeAfterFileNoSuffix]="-tree-after-$INSTANCE_ID"									# unused
	TARGET[$__deletedListFile]="-deleted-list-$INSTANCE_ID$drySuffix"								# unused
	TARGET[$__failedDeletedListFile]="-failed-delete-$INSTANCE_ID$drySuffix"
	TARGET[$__successDeletedListFile]="-success-delete-$INSTANCE_ID$drySuffix"

	PARTIAL_DIR="${INITIATOR[$__partialDir]}"

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $_LOGGER_VERBOSE == true ] || [ $_SUMMARY == true ]; then
		SYNC_OPTS=$SYNC_OPTS" -i"
	fi

	if [ $STATS == true ]; then
		SYNC_OPTS=$SYNC_OPTS" --stats"
	fi

	## Add Rsync include / exclude patterns
	RsyncPatterns

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"${INITIATOR[$__backupDir]}\""
		TARGET_BACKUP="--backup --backup-dir=\"${TARGET[$__backupDir]}\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]; then
			INITIATOR_BACKUP="$INITIATOR_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
			TARGET_BACKUP="$TARGET_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	else
		INITIATOR_BACKUP=""
		TARGET_BACKUP=""
	fi

	SYNC_ACTION=(
	'replica-tree'
	'deleted-list'
	'sync_attrs'
	'update-replica'
	'delete-propagation'
	'replica-tree-after'
	'synced'
	)
}

function Main {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	CreateStateDirs
	CheckLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$IS_STABLE" != "yes" ]; then
                echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
        fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You may use osync with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: osync.sh /path/to/config/file [OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=/path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry             Will run osync without actually doing anything; just testing"
	echo "--no-prefix       Will suppress time / date suffix from output"
	echo "--silent          Will run osync without any output to stdout, used for cron jobs"
	echo "--errors-only     Output only errors (can be combined with silent or verbose)"
	echo "--summary         Outputs a list of transferred / deleted files at the end of the run"
	echo "--verbose         Increases output"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      Disables any soft and hard execution time checks"
	echo "--force-unlock    Will override any existing active or dead locks on initiator and target replica"
	echo "--on-changes      Will launch a sync task after a short wait period if there is some file activity on initiator replica. You should try daemon mode instead"
	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--initiator=\"\"		Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 		Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"		Alternative path to rsa private key for ssh connection to target replica"
	echo "--password-file=\"\"      If no rsa private key is used for ssh authentication, a password file can be used"
	echo "--instance-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo "--skip-deletion=\"\"      You may skip deletion propagation on initiator or target. Valid values: initiator target initiator,target"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 osync.sh --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd
	local retval

	local sleepTime

	if [ "$LOCAL_OS" == "MacOSX" ]; then
		if ! type fswatch > /dev/null 2>&1 ; then
			Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	else
		if ! type inotifywait > /dev/null 2>&1 ; then
			Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	fi

	Logger "#### Running osync in file monitor mode." "NOTICE"

	while true; do
		if [ "$ConfigFile" != "" ]; then
			cmd='bash '$osync_cmd' "'$ConfigFile'" '$opts
		else
			cmd='bash '$osync_cmd' '$opts
		fi
		Logger "daemon cmd: $cmd" "DEBUG"
		eval "$cmd"
		retval=$?
		if [ $retval != 0 ] && [ $retval != 2 ]; then
			Logger "osync child exited with error." "ERROR"
		fi

		Logger "#### Monitoring now." "NOTICE"
		if [ "$LOCAL_OS" == "MacOSX" ]; then
			fswatch --exclude $OSYNC_DIR $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -1 "$INITIATOR_SYNC_DIR" > /dev/null &
			# Mac fswatch doesn't have timeout switch, replacing wait $! with WaitForTaskCompletion without warning nor spinner and increased SLEEP_TIME to avoid cpu hogging. This sims wait $! with timeout
			WaitForTaskCompletion $! 0 $MAX_WAIT 1 0 true false true ${FUNCNAME[0]}
		else
			inotifywait --exclude $OSYNC_DIR $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
			wait $!
		fi
		retval=$?
		if [ $retval == 0 ]; then
			Logger "#### Changes detected, waiting $MIN_WAIT seconds before running next sync." "NOTICE"
			sleep $MIN_WAIT
		elif [ $retval == 2 ]; then
			Logger "#### $MAX_WAIT timeout reached, running sync." "NOTICE"
		else
			Logger "#### inotify error detected, waiting $MIN_WAIT seconds before running next sync." "ERROR"
			sleep $MIN_WAIT
		fi
	done

}

#### SCRIPT ENTRY POINT

# quicksync mode settings, overriden by config file
STATS=false
PARTIAL=no
if [ "$CONFLICT_PREVALANCE" == "" ]; then
	CONFLICT_PREVALANCE=initiator
fi

INITIATOR_LOCK_FILE_EXISTS=false
TARGET_LOCK_FILE_EXISTS=false
FORCE_UNLOCK=false
no_maxtime=false
opts=""
ERROR_ALERT=false
WARN_ALERT=false
# Number of CTRL+C needed to stop script
SOFT_STOP=2
# Number of given replicas in command line
_QUICK_SYNC=0
sync_on_changes=false
_NOLOCKS=false
osync_cmd=$0
_SUMMARY=false

if [ $# -eq 0 ]
then
	Usage
fi

first=1
for i in "$@"; do
	case $i in
		--dry)
		_DRYRUN=true
		opts=$opts" --dry"
		;;
		--silent)
		_LOGGER_SILENT=true
		opts=$opts" --silent"
		;;
		--verbose)
		_LOGGER_VERBOSE=true
		opts=$opts" --verbose"
		;;
		--stats)
		STATS=true
		opts=$opts" --stats"
		;;
		--partial)
		PARTIAL="yes"
		opts=$opts" --partial"
		;;
		--force-unlock)
		FORCE_UNLOCK=true
		opts=$opts" --force-unlock"
		;;
		--no-maxtime)
		no_maxtime=true
		opts=$opts" --no-maxtime"
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--initiator=*)
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		INITIATOR_SYNC_DIR=${i##*=}
		opts=$opts" --initiator=\"$INITIATOR_SYNC_DIR\""
		;;
		--target=*)
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		TARGET_SYNC_DIR=${i##*=}
		opts=$opts" --target=\"$TARGET_SYNC_DIR\""
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
		;;
		--password-file=*)
		SSH_PASSWORD_FILE=${i##*=}
		opts=$opts" --password-file\"$SSH_PASSWORD_FILE\""
		;;
		--instance-id=*)
		INSTANCE_ID=${i##*=}
		opts=$opts" --instance-id=\"$INSTANCE_ID\""
		;;
		--skip-deletion=*)
		opts=$opts" --skip-deletion=\"${i##*=}\""
		SKIP_DELETION=${##*=}
		;;
		--on-changes)
		sync_on_changes=true
		_NOLOCKS=true
		_LOGGER_PREFIX="date"
		;;
		--no-locks)
		_NOLOCKS=true
		;;
		--errors-only)
		_LOGGER_ERR_ONLY=true
		;;
		--summary)
		_SUMMARY=true
		;;
		--no-prefix)
		_LOGGER_PREFIX=""
		;;
		*)
		if [ $first == "0" ]; then
			Logger "Unknown option '$i'" "CRITICAL"
			Usage
		fi
		;;
	esac
	first=0
done

# Remove leading space if there is one
opts="${opts# *}"

	## Here we set default options for quicksync tasks when no configuration file is provided.

	if [ $_QUICK_SYNC -eq 2 ]; then
		if [ "$INSTANCE_ID" == "" ]; then
			INSTANCE_ID="quicksync_task"
		fi

		# Let the possibility to initialize those values directly via command line like SOFT_DELETE_DAYS=60 ./osync.sh

		if [ $(IsInteger $MINIMUM_SPACE) -ne 1 ]; then
			MINIMUM_SPACE=1024
		fi

		if [ $(IsInteger $CONFLICT_BACKUP_DAYS) -ne 1 ]; then
			CONFLICT_BACKUP_DAYS=30
		fi

		if [ $(IsInteger $SOFT_DELETE_DAYS) -ne 1 ]; then
			SOFT_DELETE_DAYS=30
		fi

		if [ $(IsInteger $RESUME_TRY) -ne 1 ]; then
			RESUME_TRY=1
		fi

		if [ $(IsInteger $SOFT_MAX_EXEC_TIME) -ne 1 ]; then
			SOFT_MAX_EXEC_TIME=0
		fi
		if [ $(IsInteger $HARD_MAX_EXEC_TIME) -ne 1 ]; then
			HARD_MAX_EXEC_TIME=0
		fi

		if [ "$PATH_SEPARATOR_CHAR" == "" ]; then
			PATH_SEPARATOR_CHAR=";"
		fi

		MIN_WAIT=30
	else
		ConfigFile="${1}"
		LoadConfigFile "$ConfigFile"
	fi

if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
		LOG_FILE="$HOME/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE="./$PROGRAM.$INSTANCE_ID.log"
	fi
else
	LOG_FILE="$LOGFILE"
fi
if [ ! -w "$(dirname $LOG_FILE)" ]; then
	echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
	Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

if [ "$IS_STABLE" != "yes" ]; then
	Logger "This is an unstable dev build [$PROGRAM_BUILD]. Please use with caution." "WARN"
	fi

GetLocalOS
InitLocalOSDependingSettings
PreInit
Init
CheckEnvironment
PostInit
if [ $_QUICK_SYNC -lt 2 ]; then
	CheckCurrentConfig
fi
CheckCurrentConfigAll
DATE=$(date)
Logger "-------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING$DATE - $PROGRAM $PROGRAM_VERSION script begin." "ALWAYS"
Logger "-------------------------------------------------------------" "NOTICE"
Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"
if [ $sync_on_changes == true ]; then
	SyncOnChanges
else
	GetRemoteOS
	InitRemoteOSDependingSettings
	if [ $no_maxtime == true ]; then
		SOFT_MAX_EXEC_TIME=0
		HARD_MAX_EXEC_TIME=0
	fi
	CheckReplicaPaths
	CheckDiskSpace
	RunBeforeHook
	Main
	if [ $? == 0 ]; then
		SoftDelete
	fi
	if [ $_SUMMARY == true ]; then
		Summary
	fi
fi
