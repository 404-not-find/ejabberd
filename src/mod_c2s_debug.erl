%%%----------------------------------------------------------------------
%%% File    : mod_s2s_debug.erl
%%% Author  : Mickael Remond <mremond@process-one.net>
%%% Purpose : Log all s2s connections in a file
%%% Created :  14 Mar 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add the following line in modules section of ejabberd.cfg:
%%%              {mod_s2s_debug, [{filename, "/path/to/s2s.log"}]}
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
-module(mod_c2s_debug).

-author('mremond@process-one.net').

%% Usage:
%% In config file:
%% {mod_c2s_debug, [{logdir, "/tmp/xmpplogs"}]},
%% It is possible to limit to a specific jid with option:
%%   {users, ["test@localhost"]}
%% Warning: Only works with a single JID for now.
%%
%% Start from Erlang shell:
%% mod_c2s_debug:start("localhost", []).
%% mod_c2s_debug:stop("localhost").
%%
%% Warning: Only one module for the debug handler can be defined.

-behaviour(gen_mod).
-behavior(gen_server).

-export([start/2, start_link/2, stop/1, debug_start/3,
	 debug_stop/2, log_packet/4, log_packet/5]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_c2s.hrl").

-record(modstate, {host, logdir, pid, iodevice, user}).

-record(clientinfo, {pid, jid, auth_module, ip}).

-define(SUPERVISOR, ejabberd_sup).

-define(PROCNAME, c2s_debug).

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

%%====================================================================
%% Hooks
%%====================================================================

debug_start(_Status, Pid, C2SState) ->
    Host = C2SState#state.server,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    JID = jlib:jid_to_string(C2SState#state.jid),
    AuthModule = C2SState#state.auth_module,
    IP = C2SState#state.ip,
    ClientInfo = #clientinfo{pid = Pid, jid = JID,
			     auth_module = AuthModule, ip = IP},
    gen_server:call(Proc, {debug_start, ClientInfo}).

debug_stop(Pid, C2SState) ->
    Host = C2SState#state.server,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {debug_stop, Pid}).

log_packet(Packet, #state{debug = false}, _FromJID, _ToJID) ->
    Packet;
log_packet(Packet, #state{debug = true}, FromJID, ToJID) ->
    Host = FromJID#jid.lserver,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc,
		    {addlog, {<<"Send">>, FromJID, ToJID, Packet}}),
    Packet.

log_packet(Packet, #state{debug = false}, _JID, _FromJID, _ToJID) ->
    Packet;
log_packet(Packet, #state{debug = true}, JID, FromJID, ToJID) ->
    Host = JID#jid.lserver,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc,
		    {addlog, {<<"Receive">>, FromJID, ToJID, Packet}}),
    Packet.

init([Host, Opts]) ->
    ?INFO_MSG("Starting c2s debug module for: ~p", [Host]),
    MyHost = gen_mod:get_opt_host(Host, Opts,
				  <<"c2s_debug.@HOST@">>),
    ejabberd_hooks:add(c2s_debug_start_hook, Host, ?MODULE,
		       debug_start, 50),
    ejabberd_hooks:add(c2s_debug_stop_hook, Host, ?MODULE,
		       debug_stop, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
		       log_packet, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
		       log_packet, 50),
    Logdir = gen_mod:get_opt(logdir, Opts,
                             fun(S) ->
                                     case iolist_to_binary(S) of
                                         <<_, _/binary>> = B ->
                                             B
                                     end
                             end,
			     <<"/tmp/xmpplogs/">>),
    SJID = gen_mod:get_opt(users, Opts,
                           fun([S|_]) ->
                                   case jlib:string_to_jid(S) of
                                       #jid{} = J -> J
                                   end
                           end),
    make_dir_rec(Logdir),
    {ok,
     #modstate{host = MyHost, logdir = Logdir,
	       user = SJID}}.

terminate(_Reason, #modstate{host = Host}) ->
    ?INFO_MSG("Stopping c2s debug module for: ~s", [Host]),
    ejabberd_hooks:delete(c2s_debug_start_hook, Host,
			  ?MODULE, debug_start, 50),
    ejabberd_hooks:delete(c2s_debug_stop_hook, Host,
			  ?MODULE, debug_stop, 50),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  log_packet, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
			  log_packet, 50).

handle_call({debug_start, ClientInfo}, _From,
	    #modstate{pid = undefined, user = undefined} = State) ->
    Pid = ClientInfo#clientinfo.pid,
    ?INFO_MSG("Debug started for PID:~p", [Pid]),
    JID = ClientInfo#clientinfo.jid,
    AuthModule = ClientInfo#clientinfo.auth_module,
    IP = ClientInfo#clientinfo.ip,
    {ok, IOD} = file:open(filename(State#modstate.logdir),
			  [append]),
    Line =
	io_lib:format("~s - Session open~nJID: ~s~nAuthModule: "
		      "~p~nIP: ~p~n",
		      [timestamp(), JID, AuthModule, IP]),
    file:write(IOD, Line),
    {reply, true,
     State#modstate{pid = Pid, iodevice = IOD}};
%% Targeting a specific user
handle_call({debug_start, ClientInfo}, _From,
	    #modstate{pid = undefined, user = JID} = State) ->
    ClientJID = ClientInfo#clientinfo.jid,
    case
      jlib:jid_remove_resource(jlib:string_to_jid(ClientJID))
	of
      JID ->
	  Pid = ClientInfo#clientinfo.pid,
	  ?INFO_MSG("Debug started for PID:~p", [Pid]),
	  AuthModule = ClientInfo#clientinfo.auth_module,
	  IP = ClientInfo#clientinfo.ip,
	  {ok, IOD} = file:open(filename(State#modstate.logdir),
				[append]),
	  Line =
	      io_lib:format("~s - Session open~nJID: ~s~nAuthModule: "
			    "~p~nIP: ~p~n",
			    [timestamp(), ClientJID, AuthModule, IP]),
	  file:write(IOD, Line),
	  {reply, true,
	   State#modstate{pid = Pid, iodevice = IOD}};
      _ -> {reply, false, State}
    end;
handle_call({debug_start, _ClientInfo}, _From, State) ->
    {reply, false, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast({addlog, _},
	    #modstate{iodevice = undefined} = State) ->
    {noreply, State};
handle_cast({addlog,
	     {Direction, FromJID, ToJID, Packet}},
	    #modstate{iodevice = IOD} = State) ->
    LogEntry =
	io_lib:format("=====~n~s - ~s~nFrom: ~s~nTo: ~s~n~s~n",
		      [timestamp(), Direction, jlib:jid_to_string(FromJID),
		       jlib:jid_to_string(ToJID),
		       xml:element_to_binary(Packet)]),
    file:write(IOD, LogEntry),
    {noreply, State};
handle_cast({debug_stop, Pid},
	    #modstate{pid = Pid, iodevice = IOD} = State) ->
    Line = io_lib:format("=====~n~s - Session closed~n",
			 [timestamp()]),
    file:write(IOD, Line),
    file:close(IOD),
    {noreply,
     State#modstate{pid = undefined, iodevice = undefined}};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

filename(LogDir) ->
    Filename = lists:flatten(timestamp()) ++ "-c2s.log",
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

mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(logdir) ->
    fun (S) ->
	    case iolist_to_binary(S) of <<_, _/binary>> = B -> B end
    end;
mod_opt_type(users) ->
    fun ([S | _]) ->
	    case jlib:string_to_jid(S) of #jid{} = J -> J end
    end;
mod_opt_type(_) -> [host, logdir, users].
