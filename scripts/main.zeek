@load base/protocols/conn
@load base/utils/time


# This is probably not so great to reach into the Conn namespace..
module Conn;

export {
function set_conn_log_data_hack(c: connection)
	{
	Conn::set_conn(c, T);
	}
}

redef record Conn::Info += {
	## signals that a connection is long lived
	long: bool &log &optional;

	## signals that a connection is finished
	done: bool &log &optional;
};

# Now onto the actual code for this script...

module LongConnection;

export {
	redef enum Log::ID += { LOG };

	redef enum Notice::Type += {
		## Notice for when a long connection is found.
		## The `sub` field in the notice represents the number
		## of seconds the connection has currently been alive.
		LongConnection::found
	};

	## Aliasing vector of interval values as
	## "Durations"
	type Durations: vector of interval;

	## The default duration that you are locally 
	## considering a connection to be "long".  
	option default_durations = Durations(10min, 30min, 1hr, 12hr, 24hrs, 3days);

	## These are special cases for particular hosts or subnets
	## that you may want to watch for longer or shorter
	## durations than the default.
	option special_cases: table[subnet] of Durations = {};

	## Should the last duration be repeated or should the tracking end.
	option repeat_last_duration: bool = F;

	## Should a NOTICE be raised
	option do_notice: bool = F;

	## Write logs to the conn log vs conn_long
	option netflow_style: bool = F;

	## Event for other scripts to use
	global long_conn_found: event(c: connection);
}

redef record connection += {
	## Offset of the currently watched connection duration by the long-connections script.
	long_conn_offset: count &default=0;
};

event zeek_init() &priority=5
	{
	if ( ! netflow_style )
		Log::create_stream(LOG, [$columns=Conn::Info, $path="conn_long"]);
	}

function get_durations(c: connection): Durations
	{
	local check_it: Durations;

	if ( c$id$orig_h in special_cases )
		check_it = special_cases[c$id$orig_h];
	else if ( c$id$resp_h in special_cases )
		check_it = special_cases[c$id$resp_h];
	else
		check_it = default_durations;

	return check_it;
	}

function long_callback(c: connection, cnt: count): interval
	{
	local check_it = get_durations(c);

	if ( c$duration >= check_it[c$long_conn_offset] )
		{
		Conn::set_conn_log_data_hack(c);

		if ( netflow_style )
			{
			## Mark this connection as long lived and still active
			c$conn$long = T;
			c$conn$done = F;

			## Write to conn.log, except when Zeek is shutting down to avoid duplicate records
			if ( ! zeek_is_terminating() )
				Log::write(Conn::LOG, c$conn);
			}
		else
			Log::write(LongConnection::LOG, c$conn);

		## Write a Notice if configured to do so
		if ( do_notice )
			{
			local message = fmt("%s -> %s:%s remained alive for longer than %s", 
								c$id$orig_h, c$id$resp_h, c$id$resp_p, duration_to_mins_secs(c$duration));

			NOTICE([$note=LongConnection::found,
					$msg=message,
					$sub=fmt("%.2f", c$duration),
					$conn=c]);
			}

		## Notify other scripts that a long connection has been found
		event LongConnection::long_conn_found(c);
		}

	# Keep watching if there are potentially more thresholds.
	if ( c$long_conn_offset < |check_it|-1 )
		{
		++c$long_conn_offset;

		# Set next polling duration to be the time remaining
		# between the actual duration and the threshold duration.
		return (check_it[c$long_conn_offset] - c$duration);
		}
	else if ( repeat_last_duration )
		{
		# If repeating the final duration, don't subtract the duration
		# of the connection.
		return check_it[|check_it|-1];
		}
	else
		{
		# Negative return value here signals to stop polling
		# on this particular connection.
		return -1sec;
		}
	}

event new_connection(c: connection)
	{
	local check = get_durations(c);

	if ( |check| > 0 )
		ConnPolling::watch(c, long_callback, 1, check[0]);
	}

event connection_state_remove(c: connection)
	{
		if ( netflow_style )
			{
			if ( ! c$conn?$long )
				c$conn$long = F;

			## Mark this connectionn as complete
			c$conn$done = T;
			}
	}
