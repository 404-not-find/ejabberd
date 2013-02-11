%%%----------------------------------------------------------------------
%%% File    : gen_iq_handler.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : IQ handler support
%%% Created : 22 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
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

-module(gen_iq_handler).
-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([start_link/5,
	 add_iq_handler/6,
	 remove_iq_handler/3,
	 stop_iq_handler/3,
	 handle/7,
	 process_iq/6]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").

-record(state, {host,
		module,
		function}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Component, Host, NS, Module, Function) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Host, Module, Function], []),
    Component:register_iq_handler(Host, NS, Module, Function, Pid),
    {ok, Pid}.

add_iq_handler(Component, Host, NS, Module, Function, Type) ->
    case Type of
	no_queue ->
	    Component:register_iq_handler(Host, NS, Module, Function, no_queue);
	one_queue ->
            start_handler(Component, Host, NS, Module, Function);
	{queues, N} ->
            lists:foreach(
              fun(_) ->
                      start_handler(Component, Host, NS, Module, Function)
              end, lists:seq(1, N));
	parallel ->
	    Component:register_iq_handler(Host, NS, Module, Function, parallel)
    end.

remove_iq_handler(Component, Host, NS) ->
    Component:unregister_iq_handler(Host, NS).

stop_iq_handler(_Module, _Function, Opts) ->
    case Opts of
	[_|_] = Pids ->
	    stop_handlers(Pids);
	_ ->
	    ok
    end.

handle(Host, Module, Function, Opts, From, To, IQ) ->
    case Opts of
	no_queue ->
	    process_iq(Host, Module, Function, From, To, IQ);
        parallel ->
	    spawn(?MODULE, process_iq, [Host, Module, Function, From, To, IQ]);
	[_|_] = Pids ->
	    Pid = lists:nth(erlang:phash(now(), length(Pids)), Pids),
	    Pid ! {process_iq, From, To, IQ};
	_ ->
            ?ERROR_MSG("unexpected iqdisc options = ~p", [Opts]),
	    todo
    end.


process_iq(_Host, Module, Function, From, To, IQ) ->
    case catch Module:Function(From, To, IQ) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	ResIQ ->
	    if
		ResIQ /= ignore ->
		    ejabberd_router:route(To, From,
					  jlib:iq_to_xml(ResIQ));
		true ->
		    ok
	    end
    end.

start_handler(Component, Host, NS, Module, Function) ->
    Spec = {{?MODULE, make_ref()},
            {?MODULE, start_link, [Component, Host, NS, Module, Function]},
            permanent,
            brutal_kill,
            worker,
            [?MODULE]},
    {ok, Pid} = supervisor:start_child(ejabberd_iq_sup, Spec),
    Pid.

stop_handlers(Pids) ->
    lists:foreach(
      fun({Id, Pid, _, _}) ->
              case lists:member(Pid, Pids) of
                  true ->
                      supervisor:terminate_child(ejabberd_iq_sup, Id),
                      supervisor:delete_child(ejabberd_iq_sup, Id);
                  false ->
                      ok
              end
      end, supervisor:which_children(ejabberd_iq_sup)).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Module, Function]) ->
    {ok, #state{host = Host,
		module = Module,
		function = Function}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    Reply = ok,
    {stop, normal, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({process_iq, From, To, IQ},
	    #state{host = Host,
		   module = Module,
		   function = Function} = State) ->
    process_iq(Host, Module, Function, From, To, IQ),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
