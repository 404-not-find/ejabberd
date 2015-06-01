%%%----------------------------------------------------------------------
%%% File    : mod_mnesia_mgmt.erl
%%% Author  : Mickael Remond <mremond@process-one.net>
%%% Purpose : 
%%% Created : 
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

%% Usage:
%% In config file:
%%   mod_mnesia_mgmt:
%%     logdir: "/tmp/xmpplogs/"
%% From Erlang shell:
%% mod_mnesia_mgmt:start("localhost", []).
%% mod_mnesia_mgmt:stop("localhost").

-module(mod_mnesia_mngt).

-author('mremond@process-one.net').

-behaviour(gen_mod).

-behavior(gen_server).

-export([start/2, start_link/2, stop/1]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-record(modstate, {host = <<"">>   :: binary(),
                   logdir = <<"">> :: binary(), 
                   iodevice        :: file:io_device(),
                   timer           :: timer:tref()}).

-define(SUPERVISOR, ejabberd_sup).

-define(PROCNAME, mod_mnesia_mgmt).

-define(STANDARD_ACCEPT_INTERVAL, 20).

-define(ACCEPT_INTERVAL, 200).

-define(RATE_LIMIT_DURATION, 120000).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Spec = {Proc, {?MODULE, start_link, [Host, Opts]},
	    transient, 2000, worker, [?MODULE]},
    supervisor:start_child(?SUPERVISOR, Spec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(?SUPERVISOR, Proc).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE,
			  [Host, Opts], []).

init([Host, Opts]) ->
    ?INFO_MSG("Starting mod_mnesia_mgmt for: ~p", [Host]),
    ejabberd_listener:rate_limit([5222, 5223],
				 ?STANDARD_ACCEPT_INTERVAL),
    MyHost = gen_mod:get_opt_host(Host, Opts,
				  <<"mnesia_mngt.@HOST@">>),
    Logdir = gen_mod:get_opt(logdir, Opts,
                             fun iolist_to_binary/1,
			     <<"/tmp/xmpplogs/">>),
    make_dir_rec(binary_to_list(Logdir)),
    {ok, IOD} = file:open(filename(Logdir), [append]),
    mnesia:subscribe(system),
    {ok,
     #modstate{host = MyHost, logdir = Logdir,
	       iodevice = IOD}}.

terminate(_Reason,
	  #modstate{host = Host, iodevice = IOD}) ->
    ?INFO_MSG("Stopping mod_mnesia_mgmt for: ~s", [Host]),
    mnesia:unsubscribe(system),
    file:close(IOD).

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({mnesia_system_event,
	     {mnesia_overload,
	      {mnesia_tm, message_queue_len, Values}}},
	    #modstate{iodevice = IOD, timer = Timer} = State) ->
    Line =
	io_lib:format("~s - Mnesia overload due to message "
		      "queue length (~p)",
		      [timestamp(), Values]),
    file:write(IOD, Line),
    reset_timer(Timer),
    {messages, Messages} = process_info(whereis(mnesia_tm),
					messages),
    log_messages(IOD, Messages, 20),
    {noreply, State#modstate{timer = undefined}};
handle_info({mnesia_system_event,
	     {mnesia_overload, Details}},
	    #modstate{iodevice = IOD, timer = Timer} = State) ->
    Line = io_lib:format("~s - Mnesia overload: ~p",
			 [timestamp(), Details]),
    file:write(IOD, Line),
    reset_timer(Timer),
    {noreply, State};
handle_info({mnesia_system_event, _Event}, State) ->
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

filename(LogDir) ->
    Filename = lists:flatten(timestamp()) ++ "-mnesia.log",
    filename:join([LogDir, Filename]).

timestamp() ->
    {Y, Mo, D} = erlang:date(),
    {H, Mi, S} = erlang:time(),
    io_lib:format("~4.4.0w~2.2.0w~2.2.0w-~2.2.0w~2.2.0w~2.2.0w",
		  [Y, Mo, D, H, Mi, S]).

make_dir_rec(Dir) ->
    case file:read_file_info(Dir) of
      {ok, _} -> ok;
      {error, enoent} ->
	  DirS = filename:split(Dir),
	  DirR = lists:sublist(DirS, length(DirS) - 1),
	  make_dir_rec(filename:join(DirR)),
	  file:make_dir(Dir)
    end.

log_messages(_IOD, _Messages, 0) -> ok;
log_messages(_IOD, [], _N) -> ok;
log_messages(IOD, [Message | Messages], N) ->
    Line = io_lib:format("** ~w", [Message]),
    file:write(IOD, Line),
    log_messages(IOD, Messages, N - 1).

reset_timer(Timer) ->
    cancel_timer(Timer),
    ejabberd_listener:rate_limit([5222, 5223],
				 ?ACCEPT_INTERVAL),
    timer:apply_after(?RATE_LIMIT_DURATION,
		      ejabberd_listener, rate_limit,
		      [[5222, 5223], ?STANDARD_ACCEPT_INTERVAL]).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) -> timer:cancel(Timer).

mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(logdir) -> fun iolist_to_binary/1;
mod_opt_type(_) -> [host, logdir].
