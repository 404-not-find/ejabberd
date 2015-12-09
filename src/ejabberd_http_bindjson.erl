%%%----------------------------------------------------------------------
%%% File    : ejabberd_http_bindjson.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Implements XMPP over BOSH (XEP-0205) with a JSON Transport
%%% Created : 23 Sep 2010 by Eric Cestari <ecestari@process-one.net>
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
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_http_bindjson).

-behaviour(gen_fsm).

%% External exports
-export([start_link/3, init/1, handle_event/3,
	 handle_sync_event/4, code_change/4, handle_info/3,
	 terminate/3, send/2, send_xml/2, sockname/1, peername/1,
	 setopts/2, controlling_process/2, become_controller/2,
	 change_controller/2, custom_receiver/1, reset_stream/1,
	 change_shaper/2, monitor/1, close/1, start/4,
	 handle_session_start/8, handle_http_put/7, http_put/7,
	 http_get/2, prepare_response/4, process_request/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("http_bind.hrl").

-record(http_bind,
{
    id,
    pid,
    to,
    hold,
    wait,
    process_delay,
    version
}).

-define(NULL_PEER, {{0, 0, 0, 0}, 0}).

-record(hbr, {rid, key, out}).

-record(state,
{
    id,
    rid                  = none,
    key,
    socket,
    output               = [],
    input                = queue:new(),
    waiting_input        = false,
    shaper_state,
    shaper_timer,
    last_receiver,
    last_poll,
    http_receiver,
    wait_timer,
    ctime                = 0,
    timer,
    pause                = 0,
    unprocessed_req_list = [],
    req_list             = [],
    max_inactivity,
    max_pause,
    ip                   = ?NULL_PEER
}).

-record(http_put,
{
    rid,
    attrs,
    payload,
    payload_size,
    hold, stream,
    ip
}).

%%-define(DBGFSM, true).
-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

-define(BOSH_VERSION, <<"1.8">>).

-define(NS_CLIENT, <<"jabber:client">>).

-define(NS_BOSH, <<"urn:xmpp:xbosh">>).

-define(NS_HTTP_BIND,
	<<"http://jabber.org/protocol/httpbind">>).

-define(MAX_REQUESTS, 2).

-define(MIN_POLLING, 2000000).

-define(MAX_WAIT, 3600).

-define(MAX_INACTIVITY, 30000).

-define(MAX_PAUSE, 120).

-define(PROCESS_DELAY_DEFAULT, 100).

-define(PROCESS_DELAY_MIN, 0).

-define(PROCESS_DELAY_MAX, 1000).

start(XMPPDomain, Sid, Key, IP) ->
    ?DEBUG("Starting session", []),
    case catch gen_fsm:start(?MODULE,
			    [Sid, Key, IP],
			    ?FSMOPTS) of
      {ok, Pid} -> {ok, Pid};
      {error, _} = Err ->
	  case check_bind_module(XMPPDomain) of
	    false -> {error, <<"Cannot start HTTP bind session">>};
	    true ->
		?ERROR_MSG("Cannot start HTTP bind session: ~p", [Err]),
		Err
	  end;
      Exit ->
	  ?ERROR_MSG("Cannot start HTTP bind session: ~p",
		     [Exit]),
	  {error, Exit}
    end.

start_link(Sid, Key, IP) ->
    gen_fsm:start_link(?MODULE, [Sid, Key, IP], ?FSMOPTS).

send({http_bind, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {send, Packet}).

send_xml({http_bind, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {send_xml, Packet}).

setopts({http_bind, FsmRef, _IP}, Opts) ->
    case lists:member({active, once}, Opts) of
      true ->
	  gen_fsm:send_all_state_event(FsmRef,
				       {activate, self()});
      _ ->
	  case lists:member({active, false}, Opts) of
	    true ->
		gen_fsm:sync_send_all_state_event(FsmRef,
						  deactivate_socket);
	    _ -> ok
	  end
    end.

controlling_process(_Socket, _Pid) -> ok.

custom_receiver({http_bind, FsmRef, _IP}) ->
    {receiver, ?MODULE, FsmRef}.

become_controller(FsmRef, C2SPid) ->
    gen_fsm:send_all_state_event(FsmRef,
				 {become_controller, C2SPid}).

change_controller({http_bind, FsmRef, _IP}, C2SPid) ->
    become_controller(FsmRef, C2SPid).

reset_stream({http_bind, _FsmRef, _IP}) -> ok.

change_shaper({http_bind, FsmRef, _IP}, Shaper) ->
    gen_fsm:send_all_state_event(FsmRef,
				 {change_shaper, Shaper}).

monitor({http_bind, FsmRef, _IP}) ->
    erlang:monitor(process, FsmRef).

close({http_bind, FsmRef, _IP}) ->
    catch gen_fsm:sync_send_all_state_event(FsmRef,
					    {stop, close}).

sockname(_Socket) -> {ok, ?NULL_PEER}.

peername({http_bind, _FsmRef, IP}) -> {ok, IP}.

process_request(Data, IP) ->
    Opts1 = ejabberd_c2s_config:get_c2s_limits(),
    Opts = [{xml_socket, true} | Opts1],
    MaxStanzaSize = case lists:keysearch(max_stanza_size, 1,
					 Opts)
			of
		      {value, {_, Size}} -> Size;
		      _ -> infinity
		    end,
    PayloadSize = iolist_size(Data),
    case catch parse_request(Data, PayloadSize,
			     MaxStanzaSize)
	of
      %% No existing session:
      {ok, {<<"">>, Rid, Attrs, Payload}} ->
	  case xml:get_attr_s(<<"to">>, Attrs) of
	    <<"">> ->
		?DEBUG("Session not created (Improper addressing)", []),
		{200, ?HEADER,
		 <<"{\"body\":{\"type\":\"terminate\" \"condition\""
		   ":\"improper-addressing\", \"xmlns\":\"",
		   (?NS_HTTP_BIND)/binary, "\"}}">>};
	    XmppDomain ->
		Sid = make_sid(),
		case start(XmppDomain, Sid, <<"">>, IP) of
		  {error, _} ->
		      {500, ?HEADER,
		       <<"{\"body\":{\"type\":\"terminate\" \"condition\""
			 ":\"internal-server-error\", \"xmlns\":\"",
			 (?NS_HTTP_BIND)/binary,
			 "\",\"$\":\"Internal Server Error\"}}">>};
		  {ok, Pid} ->
		      handle_session_start(Pid, XmppDomain, Sid, Rid, Attrs,
					   Payload, PayloadSize, IP)
		end
	  end;
      %% Existing session
      {ok, {Sid, Rid, Attrs, Payload1}} ->
	  StreamStart = case xml:get_attr_s(<<"xmpp:restart">>,
					    Attrs)
			    of
			  <<"true">> -> true;
			  _ -> false
			end,
	  Payload2 = case xml:get_attr_s(<<"type">>, Attrs) of
		       <<"terminate">> ->
			   Payload1 ++ [{xmlstreamend, <<"stream:stream">>}];
		       _ -> Payload1
		     end,
	  handle_http_put(Sid, Rid, Attrs, Payload2, PayloadSize,
			  StreamStart, IP);
      {size_limit, Sid} ->
	  case get_session(Sid) of
	    {error, _} -> {404, ?HEADER, <<"">>};
	    {ok, #http_bind{pid = FsmRef}} ->
		gen_fsm:sync_send_all_state_event(FsmRef,
						  {stop, close}),
		{200, ?HEADER,
		 <<"{\"body\": {\"type\"=\"terminate\" \"conditio"
		   "n\":\"undefined-condition\" \"xmlns\":\"",
		   (?NS_HTTP_BIND)/binary,
		   "\", \"$\":\"Request Too Large\"}}">>}
	  end;
      _ ->
	  ?DEBUG("Received bad request: ~p", [Data]),
	  {400, ?HEADER, <<"">>}
    end.

handle_session_start(Pid, XmppDomain, Sid, Rid, Attrs,
		     Payload, PayloadSize, IP) ->
    ?DEBUG("got pid: ~p", [Pid]),
    Wait = case str:to_integer(xml:get_attr_s(<<"wait">>,
					      Attrs))
	       of
	     {error, _} -> ?MAX_WAIT;
	     {CWait, _} ->
		 if CWait > (?MAX_WAIT) -> ?MAX_WAIT;
		    true -> CWait
		 end
	   end,
    Hold = case str:to_integer(xml:get_attr_s(<<"hold">>,
					      Attrs))
	       of
	     {error, _} -> (?MAX_REQUESTS) - 1;
	     {CHold, _} ->
		 if CHold > (?MAX_REQUESTS) - 1 -> (?MAX_REQUESTS) - 1;
		    true -> CHold
		 end
	   end,
    Pdelay = case
	       str:to_integer(xml:get_attr_s(<<"process-delay">>,
					     Attrs))
		 of
	       {error, _} -> ?PROCESS_DELAY_DEFAULT;
	       {CPdelay, _}
		   when ((?PROCESS_DELAY_MIN) =< CPdelay) and
			  (CPdelay =< (?PROCESS_DELAY_MAX)) ->
		   CPdelay;
	       {CPdelay, _} ->
		   erlang:max(erlang:min(CPdelay, ?PROCESS_DELAY_MAX),
			      ?PROCESS_DELAY_MIN)
	     end,
    Version = case catch
		     list_to_float(binary_to_list(xml:get_attr_s(<<"ver">>, Attrs)))
		  of
		{'EXIT', _} -> 0.0;
		V -> V
	      end,
    XmppVersion = xml:get_attr_s(<<"xmpp:version">>, Attrs),
    ?DEBUG("Create session: ~p", [Sid]),
    mnesia:async_dirty(fun () ->
			       mnesia:write(#http_bind{id = Sid, pid = Pid,
						       to =
							   {XmppDomain,
							    XmppVersion},
						       hold = Hold, wait = Wait,
						       process_delay = Pdelay,
						       version = Version})
		       end),
    handle_http_put(Sid, Rid, Attrs, Payload, PayloadSize,
		    true, IP).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

init([Sid, Key, IP]) ->
    ?DEBUG("started: ~p", [{Sid, Key, IP}]),
    Opts1 = ejabberd_c2s_config:get_c2s_limits(),
    Opts = [{xml_socket, true} | Opts1],
    Shaper = none,
    ShaperState = shaper:new(Shaper),
    Socket = {http_bind, self(), IP},
    ejabberd_socket:start(ejabberd_c2s, ?MODULE, Socket,
			  Opts),
    Timer = erlang:start_timer(?MAX_INACTIVITY, self(), []),
    {ok, loop,
     #state{id = Sid, key = Key, socket = Socket,
	    shaper_state = ShaperState,
	    max_inactivity = ?MAX_INACTIVITY,
	    max_pause = ?MAX_PAUSE, timer = Timer}}.

handle_event({become_controller, C2SPid}, StateName,
	     StateData) ->
    erlang:monitor(process, C2SPid),
    case StateData#state.input of
      cancel ->
	  {next_state, StateName,
	   StateData#state{waiting_input = C2SPid}};
      Input ->
	  lists:foreach(fun (Event) -> C2SPid ! Event end,
			queue:to_list(Input)),
	  {next_state, StateName,
	   StateData#state{input = queue:new(),
			   waiting_input = C2SPid}}
    end;
handle_event({change_shaper, Shaper}, StateName,
	     StateData) ->
    NewShaperState = shaper:new(Shaper),
    {next_state, StateName,
     StateData#state{shaper_state = NewShaperState}};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event({send_xml, Packet}, _From, StateName,
		  #state{http_receiver = undefined} = StateData) ->
    Output = [Packet | StateData#state.output],
    Reply = ok,
    {reply, Reply, StateName,
     StateData#state{output = Output}};
handle_sync_event({send_xml, Packet}, _From, StateName,
		  StateData) ->
    Output = [Packet | StateData#state.output],
    cancel_timer(StateData#state.timer),
    Timer = set_inactivity_timer(StateData#state.pause,
				 StateData#state.max_inactivity),
    HTTPReply = {ok, Output},
    gen_fsm:reply(StateData#state.http_receiver, HTTPReply),
    cancel_timer(StateData#state.wait_timer),
    Rid = StateData#state.rid,
    ReqList = [#hbr{rid = Rid, key = StateData#state.key,
		    out = Output}
	       | [El
		  || El <- StateData#state.req_list, El#hbr.rid /= Rid]],
    Reply = ok,
    {reply, Reply, StateName,
     StateData#state{output = [], http_receiver = undefined,
		     req_list = ReqList, wait_timer = undefined,
		     timer = Timer}};
handle_sync_event({stop, close}, _From, _StateName,
		  StateData) ->
    Reply = ok, {stop, normal, Reply, StateData};
handle_sync_event({stop, stream_closed}, _From,
		  _StateName, StateData) ->
    Reply = ok, {stop, normal, Reply, StateData};
handle_sync_event(deactivate_socket, _From, StateName,
		  StateData) ->
    {reply, ok, StateName,
     StateData#state{waiting_input = false}};
handle_sync_event({stop, Reason}, _From, _StateName,
		  StateData) ->
    ?DEBUG("Closing bind session ~p - Reason: ~p",
	   [StateData#state.id, Reason]),
    Reply = ok,
    {stop, normal, Reply, StateData};
%% HTTP PUT: Receive packets from the client
handle_sync_event(#http_put{rid = Rid}, _From,
		  StateName, StateData)
    when StateData#state.shaper_timer /= undefined ->
    Pause = case
	      erlang:read_timer(StateData#state.shaper_timer)
		of
	      false -> 0;
	      P -> P
	    end,
    Reply = {wait, Pause},
    ?DEBUG("Shaper timer for RID ~p: ~p", [Rid, Reply]),
    {reply, Reply, StateName, StateData};
handle_sync_event(#http_put{payload_size =
				PayloadSize} =
		      Request,
		  _From, StateName, StateData) ->
    ?DEBUG("New request: ~p", [Request]),
    {NewShaperState, NewShaperTimer} =
	update_shaper(StateData#state.shaper_state,
		      PayloadSize),
    handle_http_put_event(Request, StateName,
			  StateData#state{shaper_state = NewShaperState,
					  shaper_timer = NewShaperTimer});
%% HTTP GET: send packets to the client
handle_sync_event({http_get, Rid, Wait, Hold}, From,
		  StateName, StateData) ->
    send_receiver_reply(StateData#state.http_receiver,
			{ok, empty}),
    cancel_timer(StateData#state.wait_timer),
    TNow = p1_time_compat:system_time(micro_seconds),
    if (Hold > 0) and (StateData#state.output == []) and
	 (TNow - StateData#state.ctime < Wait * 1000 * 1000)
	 and (StateData#state.rid == Rid)
	 and (StateData#state.input /= cancel)
	 and (StateData#state.pause == 0) ->
	   WaitTimer = erlang:start_timer(Wait * 1000, self(), []),
	   cancel_timer(StateData#state.timer),
	   {next_state, StateName,
	    StateData#state{http_receiver = From,
			    wait_timer = WaitTimer, timer = undefined}};
       StateData#state.input == cancel ->
	   cancel_timer(StateData#state.timer),
	   Timer = set_inactivity_timer(StateData#state.pause,
					StateData#state.max_inactivity),
	   Reply = {ok, cancel},
	   {reply, Reply, StateName,
	    StateData#state{input = queue:new(),
			    http_receiver = undefined, wait_timer = undefined,
			    timer = Timer}};
       true ->
	   cancel_timer(StateData#state.timer),
	   Timer = set_inactivity_timer(StateData#state.pause,
					StateData#state.max_inactivity),
	   Reply = {ok, StateData#state.output},
	   ReqList = [#hbr{rid = Rid, key = StateData#state.key,
			   out = StateData#state.output}
		      | [El
			 || El <- StateData#state.req_list, El#hbr.rid /= Rid]],
	   {reply, Reply, StateName,
	    StateData#state{output = [], http_receiver = undefined,
			    wait_timer = undefined, timer = Timer,
			    req_list = ReqList}}
    end;
handle_sync_event(peername, _From, StateName,
		  StateData) ->
    Reply = {ok, StateData#state.ip},
    {reply, Reply, StateName, StateData};
handle_sync_event(_Event, _From, StateName,
		  StateData) ->
    Reply = ok, {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

handle_info({timeout, Timer, _}, _StateName,
	    #state{id = SID, timer = Timer} = StateData) ->
    ?INFO_MSG("Session timeout. Closing the HTTP bind "
	      "session: ~p",
	      [SID]),
    {stop, normal, StateData};
handle_info({timeout, WaitTimer, _}, StateName,
	    #state{wait_timer = WaitTimer} = StateData) ->
    if StateData#state.http_receiver /= undefined ->
	   cancel_timer(StateData#state.timer),
	   Timer = set_inactivity_timer(StateData#state.pause,
					StateData#state.max_inactivity),
	   gen_fsm:reply(StateData#state.http_receiver,
			 {ok, empty}),
	   Rid = StateData#state.rid,
	   ReqList = [#hbr{rid = Rid, key = StateData#state.key,
			   out = []}
		      | [El
			 || El <- StateData#state.req_list, El#hbr.rid /= Rid]],
	   {next_state, StateName,
	    StateData#state{http_receiver = undefined,
			    req_list = ReqList, wait_timer = undefined,
			    timer = Timer}};
       true -> {next_state, StateName, StateData}
    end;
handle_info({timeout, ShaperTimer, _}, StateName,
	    #state{shaper_timer = ShaperTimer} = StateData) ->
    {next_state, StateName,
     StateData#state{shaper_timer = undefined}};
handle_info({'DOWN', _MRef, process, C2SPid, _},
	    _StateName,
	    #state{waiting_input = C2SPid} = StateData) ->
    {stop, normal, StateData};
handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

terminate(_Reason, _StateName, StateData) ->
    ?DEBUG("terminate: Deleting session ~s",
	   [StateData#state.id]),
    mnesia:dirty_delete({http_bind, StateData#state.id}),
    send_receiver_reply(StateData#state.http_receiver,
			{ok, terminate}),
    case StateData#state.waiting_input of
      false -> ok;
      C2SPid -> gen_fsm:send_event(C2SPid, closed)
    end,
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

handle_http_put_event(#http_put{rid = Rid,
				attrs = Attrs, hold = Hold} =
			  Request,
		      StateName, StateData) ->
    ?DEBUG("New request: ~p", [Request]),
    RidAllow = rid_allow(StateData#state.rid, Rid, Attrs,
			 Hold, StateData#state.max_pause),
    case RidAllow of
      buffer ->
	  ?DEBUG("Buffered request: ~p", [Request]),
	  PendingRequests = StateData#state.unprocessed_req_list,
	  Requests = lists:keydelete(Rid, 2, PendingRequests),
	  ReqList = [#hbr{rid = Rid, key = StateData#state.key,
			  out = []}
		     | [El
			|| El <- StateData#state.req_list,
			   El#hbr.rid > Rid - 1 - Hold]],
	  ?DEBUG("reqlist: ~p", [ReqList]),
	  UnprocessedReqList = [Request | Requests],
	  cancel_timer(StateData#state.timer),
	  Timer = set_inactivity_timer(0,
				       StateData#state.max_inactivity),
	  {reply, buffered, StateName,
	   StateData#state{unprocessed_req_list =
			       UnprocessedReqList,
			   req_list = ReqList, timer = Timer}};
      _ ->
	  process_http_put(Request, StateName, StateData,
			   RidAllow)
    end.

process_http_put(#http_put{rid = Rid, attrs = Attrs,
			   payload = Payload, hold = Hold, stream = StreamTo,
			   ip = IP} =
		     Request,
		 StateName, StateData, RidAllow) ->
    ?DEBUG("Actually processing request: ~p", [Request]),
    Key = xml:get_attr_s(<<"key">>, Attrs),
    NewKey = xml:get_attr_s(<<"newkey">>, Attrs),
    KeyAllow = case RidAllow of
		 repeat -> true;
		 false -> false;
		 {true, _} ->
		     case StateData#state.key of
		       <<"">> -> true;
		       OldKey ->
			   NextKey = p1_sha:sha(Key),
			   ?DEBUG("Key/OldKey/NextKey: ~s/~s/~s",
				  [Key, OldKey, NextKey]),
			   if OldKey == NextKey -> true;
			      true -> ?DEBUG("wrong key: ~s", [Key]), false
			   end
		     end
	       end,
    TNow = p1_time_compat:system_time(micro_seconds),
    LastPoll = if Payload == [] -> TNow;
		  true -> 0
	       end,
    if (Payload == []) and (Hold == 0) and
	 (TNow - StateData#state.last_poll < (?MIN_POLLING)) ->
	   Reply = {error, polling_too_frequently},
	   {reply, Reply, StateName, StateData};
       KeyAllow ->
	   case RidAllow of
	     false ->
		 Reply = {error, not_exists},
		 {reply, Reply, StateName, StateData};
	     repeat ->
		 ?DEBUG("REPEATING ~p", [Rid]),
		 Reply = case [El#hbr.out
			       || El <- StateData#state.req_list,
				  El#hbr.rid == Rid]
			     of
			   [] -> {error, not_exists};
			   [Out | _XS] -> {repeat, lists:reverse(Out)}
			 end,
		 {reply, Reply, StateName,
		  StateData#state{input = cancel, last_poll = LastPoll}};
	     {true, Pause} ->
		 SaveKey = if NewKey == <<"">> -> Key;
			      true -> NewKey
			   end,
		 ?DEBUG(" -- SaveKey: ~s~n", [SaveKey]),
		 ReqList1 = [El
			     || El <- StateData#state.req_list,
				El#hbr.rid > Rid - 1 - Hold],
		 ReqList = case lists:keymember(Rid, #hbr.rid, ReqList1)
			       of
			     true -> ReqList1;
			     false ->
				 [#hbr{rid = Rid, key = StateData#state.key,
				       out = []}
				  | ReqList1]
			   end,
		 ?DEBUG("reqlist: ~p", [ReqList]),
		 cancel_timer(StateData#state.timer),
		 Timer = set_inactivity_timer(Pause,
					      StateData#state.max_inactivity),
		 case StateData#state.waiting_input of
		   false ->
		       Input = lists:foldl(fun queue:in/2,
					   StateData#state.input, Payload),
		       Reply = ok,
		       process_buffered_request(Reply, StateName,
						StateData#state{input = Input,
								rid = Rid,
								key = SaveKey,
								ctime = TNow,
								timer = Timer,
								pause = Pause,
								last_poll =
								    LastPoll,
								req_list =
								    ReqList,
								ip = IP});
		   C2SPid ->
		       case StreamTo of
			 {To, <<"">>} ->
			     gen_fsm:send_event(C2SPid,
						{xmlstreamstart,
						 <<"stream:stream">>,
						 [{<<"to">>, To},
						  {<<"xmlns">>, ?NS_CLIENT},
						  {<<"xmlns:stream">>,
						   ?NS_STREAM}]});
			 {To, Version} ->
			     gen_fsm:send_event(C2SPid,
						{xmlstreamstart,
						 <<"stream:stream">>,
						 [{<<"to">>, To},
						  {<<"xmlns">>, ?NS_CLIENT},
						  {<<"version">>, Version},
						  {<<"xmlns:stream">>,
						   ?NS_STREAM}]});
			 _ -> ok
		       end,
		       MaxInactivity = get_max_inactivity(StreamTo,
							  StateData#state.max_inactivity),
		       MaxPause = get_max_inactivity(StreamTo,
						     StateData#state.max_pause),
		       ?DEBUG("really sending now: ~p", [Payload]),
		       lists:foreach(fun ({xmlstreamend, End}) ->
					     gen_fsm:send_event(C2SPid,
								{xmlstreamend,
								 End});
					 (El) ->
					     gen_fsm:send_event(C2SPid,
								{xmlstreamelement,
								 El})
				     end,
				     Payload),
		       Reply = ok,
		       process_buffered_request(Reply, StateName,
						StateData#state{input =
								    queue:new(),
								rid = Rid,
								key = SaveKey,
								ctime = TNow,
								timer = Timer,
								pause = Pause,
								last_poll =
								    LastPoll,
								req_list =
								    ReqList,
								max_inactivity =
								    MaxInactivity,
								max_pause =
								    MaxPause,
								ip = IP})
		 end
	   end;
       true ->
	   Reply = {error, bad_key},
	   {reply, Reply, StateName, StateData}
    end.

process_buffered_request(Reply, StateName, StateData) ->
    Rid = StateData#state.rid,
    Requests = StateData#state.unprocessed_req_list,
    case lists:keysearch(Rid + 1, 2, Requests) of
      {value, Request} ->
	  ?DEBUG("Processing buffered request: ~p", [Request]),
	  NewRequests = lists:keydelete(Rid + 1, 2, Requests),
	  handle_http_put_event(Request, StateName,
				StateData#state{unprocessed_req_list =
						    NewRequests});
      _ -> {reply, Reply, StateName, StateData, hibernate}
    end.

handle_http_put(Sid, Rid, Attrs, Payload, PayloadSize,
		StreamStart, IP) ->
    case http_put(Sid, Rid, Attrs, Payload, PayloadSize,
		  StreamStart, IP)
	of
      {error, not_exists} ->
	  ?DEBUG("no session associated with sid: ~p", [Sid]),
	  {404, ?HEADER, <<"">>};
      {{error, Reason}, Sess} ->
	  ?DEBUG("Error on HTTP put. Reason: ~p", [Reason]),
	  handle_http_put_error(Reason, Sess);
      {{repeat, OutPacket}, Sess} ->
	  ?DEBUG("http_put said \"repeat!\" ...~nOutPacket: ~p",
		 [OutPacket]),
	  send_outpacket(Sess, OutPacket);
      {{wait, Pause}, _Sess} ->
	  ?DEBUG("Trafic Shaper: Delaying request ~p", [Rid]),
	  timer:sleep(Pause),
	  handle_http_put(Sid, Rid, Attrs, Payload, PayloadSize,
			  StreamStart, IP);
      {buffered, _Sess} ->
	  {200, ?HEADER,
	   <<"{\"body\":{ \"xmlns\":\"", (?NS_HTTP_BIND)/binary,
	     "\"}}">>};
      {ok, Sess} ->
	  prepare_response(Sess, Rid, [], StreamStart)
    end.

http_put(Sid, Rid, Attrs, Payload, PayloadSize,
	 StreamStart, IP) ->
    ?DEBUG("Looking for session: ~p", [Sid]),
    case get_session(Sid) of
      {error, _} -> {error, not_exists};
      {ok,
       #http_bind{pid = FsmRef, hold = Hold,
		  to = {To, StreamVersion}} =
	   Sess} ->
	  NewStream = case StreamStart of
			true -> {To, StreamVersion};
			_ -> <<"">>
		      end,
	  {gen_fsm:sync_send_all_state_event(FsmRef,
					     #http_put{rid = Rid, attrs = Attrs,
						       payload = Payload,
						       payload_size =
							   PayloadSize,
						       hold = Hold,
						       stream = NewStream,
						       ip = IP},
					     30000),
	   Sess}
    end.

handle_http_put_error(Reason,
		      #http_bind{pid = FsmRef, version = Version})
    when Version >= 0 ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {stop, {put_error, Reason}}),
    case Reason of
      not_exists ->
	  {200, ?HEADER,
	   jiffy:encode(xmpp_json:to_json(#xmlel{name =
							  <<"body">>,
						      attrs =
							  [{<<"xmlns">>,
							    ?NS_HTTP_BIND},
							   {<<"type">>,
							    <<"terminate">>},
							   {<<"condition">>,
							    <<"item-not-found">>}],
						      children = []}))};
      bad_key ->
	  {200, ?HEADER,
	   jiffy:encode(xmpp_json:to_json(#xmlel{name =
							  <<"body">>,
						      attrs =
							  [{<<"xmlns">>,
							    ?NS_HTTP_BIND},
							   {<<"type">>,
							    <<"terminate">>},
							   {<<"condition">>,
							    <<"item-not-found">>}],
						      children = []}))};
      polling_too_frequently ->
	  {200, ?HEADER,
	   jiffy:encode(xmpp_json:to_json(#xmlel{name =
							  <<"body">>,
						      attrs =
							  [{<<"xmlns">>,
							    ?NS_HTTP_BIND},
							   {<<"type">>,
							    <<"terminate">>},
							   {<<"condition">>,
							    <<"policy-violation">>}],
						      children = []}))}
    end;
handle_http_put_error(Reason,
		      #http_bind{pid = FsmRef}) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {stop, {put_error_no_version, Reason}}),
    case Reason of
      not_exists -> %% bad rid
	  ?DEBUG("Closing HTTP bind session (Bad rid).", []),
	  {404, ?HEADER, <<"">>};
      bad_key ->
	  ?DEBUG("Closing HTTP bind session (Bad key).", []),
	  {404, ?HEADER, <<"">>};
      polling_too_frequently ->
	  ?DEBUG("Closing HTTP bind session (User polling "
		 "too frequently).",
		 []),
	  {403, ?HEADER, <<"">>}
    end.

rid_allow(none, _NewRid, _Attrs, _Hold, _MaxPause) ->
    {true, 0};
rid_allow(OldRid, NewRid, Attrs, Hold, MaxPause) ->
    ?DEBUG("Previous rid / New rid: ~p/~p",
	   [OldRid, NewRid]),
    if
      %% We did not miss any packet, we can process it immediately:
      NewRid == OldRid + 1 ->
	  case catch
		 jlib:binary_to_integer(xml:get_attr_s(<<"pause">>,
							 Attrs))
	      of
	    {'EXIT', _} -> {true, 0};
	    Pause1 when Pause1 =< MaxPause ->
		?DEBUG("got pause: ~p", [Pause1]), {true, Pause1};
	    _ -> {true, 0}
	  end;
      %% We have missed packets, we need to cached it to process it later on:
      (OldRid < NewRid) and (NewRid =< OldRid + Hold + 1) ->
	  buffer;
      (NewRid =< OldRid) and (NewRid > OldRid - Hold - 1) ->
	  repeat;
      true -> false
    end.

update_shaper(ShaperState, PayloadSize) ->
    {NewShaperState, Pause} = shaper:update(ShaperState,
					    PayloadSize),
    if Pause > 0 ->
	   ShaperTimer = erlang:start_timer(Pause, self(),
					    activate),
	   {NewShaperState, ShaperTimer};
       true -> {NewShaperState, undefined}
    end.

prepare_response(Sess, Rid, OutputEls, StreamStart) ->
    receive  after Sess#http_bind.process_delay -> ok end,
    case catch http_get(Sess, Rid) of
      {ok, cancel} ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"type\":\"error\", \"xmlns\":\"",
	     (?NS_HTTP_BIND)/binary, "\"/>">>};
      {ok, empty} ->
	  {200, ?HEADER,
	   <<"{\"body\":{ \"xmlns\":\"", (?NS_HTTP_BIND)/binary,
	     "\"}}">>};
      {ok, terminate} ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"type\":\"terminate\", "
	     "\"xmlns\":\"",
	     (?NS_HTTP_BIND)/binary, "\"/>">>};
      {ok, ROutPacket} ->
	  OutPacket = lists:reverse(ROutPacket),
	  ?DEBUG("OutPacket: ~p", [OutputEls ++ OutPacket]),
	  prepare_outpacket_response(Sess, Rid,
				     OutputEls ++ OutPacket, StreamStart);
      {'EXIT', {shutdown, _}} ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"type\":\"terminate\",\"conditio"
	     "n\":\"system-shutdown\", \"xmlns\":\"",
	     (?NS_HTTP_BIND)/binary, "\"}}">>};
      {'EXIT', _Reason} ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"type\":\"terminate, \"xmlns\":\"",
	     (?NS_HTTP_BIND)/binary, "\"}}">>}
    end.

prepare_outpacket_response(Sess, _Rid, OutPacket,
			   false) ->
    case catch send_outpacket(Sess, OutPacket) of
      {'EXIT', _Reason} ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"type\":\"terminate\", "
	     "\"xmlns\":\"",
	     (?NS_HTTP_BIND)/binary, "\"}}">>};
      SendRes -> SendRes
    end;
%% Handle a new session along with its output payload
prepare_outpacket_response(#http_bind{id = Sid,
				      wait = Wait, hold = Hold, to = To} =
			       Sess,
			   Rid, OutPacket, true) ->
    case OutPacket of
      [{xmlstreamstart, _, OutAttrs} | Els] ->
	  AuthID = xml:get_attr_s(<<"id">>, OutAttrs),
	  From = xml:get_attr_s(<<"from">>, OutAttrs),
	  Version = xml:get_attr_s(<<"version">>, OutAttrs),
	  OutEls = case Els of
		     [] -> [];
		     [{xmlstreamelement,
		       #xmlel{name = <<"stream:features">>,
			      attrs = StreamAttribs, children = StreamEls}}
		      | StreamTail] ->
			 TypedTail = [check_default_xmlns(OEl)
				      || {xmlstreamelement, OEl} <- StreamTail],
			 [#xmlel{name = <<"stream:features">>,
				 attrs =
				     [{<<"xmlns:stream">>, ?NS_STREAM}] ++
				       StreamAttribs,
				 children = StreamEls}]
			   ++ TypedTail;
		     StreamTail ->
			 [check_default_xmlns(OEl)
			  || {xmlstreamelement, OEl} <- StreamTail]
		   end,
	  case OutEls of
	    [] -> prepare_response(Sess, Rid, OutPacket, true);
	    [#xmlel{name = <<"stream:error">>}] ->
		{200, ?HEADER,
		 <<"{\"body\" : {\"type\":\"terminate\", "
		   "\"condition\":\"host-unknown\", \"xmlns\"=\"",
		   (?NS_HTTP_BIND)/binary, "\"}}">>};
	    _ ->
		BOSH_attribs = [{<<"authid">>, AuthID},
				{<<"xmlns:xmpp">>, ?NS_BOSH},
				{<<"xmlns:stream">>, ?NS_STREAM},
				{<<"xmpp:version">>, Version}],
%				 ++
%				 case OutEls of
%				   [] -> [];
%				   _ -> [{<<"xmpp:version">>, Version}]
%				 end,
		MaxInactivity = get_max_inactivity(To, ?MAX_INACTIVITY),
		MaxPause = get_max_pause(To),
		{200, ?HEADER,
		 jiffy:encode(xmpp_json:to_json(#xmlel{name =
								<<"body">>,
							    attrs =
								[{<<"xmlns">>,
								  ?NS_HTTP_BIND},
								 {<<"sid">>,
								  Sid},
								 {<<"wait">>,
								  iolist_to_binary(integer_to_list(Wait))},
								 {<<"requests">>,
								  iolist_to_binary(integer_to_list(Hold
												     +
												     1))},
								 {<<"inactivity">>,
								  iolist_to_binary(integer_to_list(trunc(MaxInactivity
													   /
													   1000)))},
								 {<<"maxpause">>,
								  iolist_to_binary(integer_to_list(MaxPause))},
								 {<<"polling">>,
								  iolist_to_binary(integer_to_list(trunc((?MIN_POLLING)
													   /
													   1000000)))},
								 {<<"ver">>,
								  ?BOSH_VERSION},
								 {<<"from">>,
								  From},
								 {<<"secure">>,
								  <<"true">>}]
								  ++
								  BOSH_attribs,
							    children =
								OutEls}))}
	  end;
      _ ->
	  {200, ?HEADER,
	   <<"{\"body\" : {\"type\":\"terminate\", "
	     "\"condition\":\"internal-server-error\", "
	     "\"xmlns\"=\"",
	     (?NS_HTTP_BIND)/binary, "\"}}">>}
    end.

http_get(#http_bind{pid = FsmRef, wait = Wait,
		    hold = Hold},
	 Rid) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {http_get, Rid, Wait, Hold},
				      2 * (?MAX_WAIT) * 1000).

send_outpacket(#http_bind{pid = FsmRef}, OutPacket) ->
    case OutPacket of
      [] ->
	  {200, ?HEADER,
	   <<"{\"body\": {\"xmlns\":\"", (?NS_HTTP_BIND)/binary,
	     "\"}}">>};
      [{xmlstreamend, _}] ->
	  gen_fsm:sync_send_all_state_event(FsmRef,
					    {stop, stream_closed}),
	  {200, ?HEADER,
	   <<"{\"body\": {\"xmlns\":", (?NS_HTTP_BIND)/binary,
	     "\"}}">>};
      _ ->
	  AllElements = lists:all(fun ({xmlstreamelement,
					#xmlel{name = <<"stream:error">>}}) ->
					  false;
				      ({xmlstreamelement, _}) -> true;
				      (_) -> false
				  end,
				  OutPacket),
	  case AllElements of
	    true ->
		TypedEls = [check_default_xmlns(OEl)
			    || {xmlstreamelement, OEl} <- OutPacket],
		Body = jiffy:encode(xmpp_json:to_json(#xmlel{name =
								      <<"body">>,
								  attrs =
								      [{<<"xmlns">>,
									?NS_HTTP_BIND}],
								  children =
								      TypedEls})),
		?DEBUG(" --- outgoing data --- ~n~s~n --- END "
		       "--- ~n",
		       [Body]),
		{200, ?HEADER, Body};
	    false ->
		case OutPacket of
		  [{xmlstreamstart, _, _} | SEls] ->
		      OutEls = case SEls of
				 [{xmlstreamelement,
				   #xmlel{name = <<"stream:features">>,
					  attrs = StreamAttribs,
					  children = StreamEls}}
				  | StreamTail] ->
				     TypedTail = [check_default_xmlns(OEl)
						  || {xmlstreamelement, OEl}
							 <- StreamTail],
				     [#xmlel{name = <<"stream:features">>,
					     attrs =
						 [{<<"xmlns:stream">>,
						   ?NS_STREAM}]
						   ++ StreamAttribs,
					     children = StreamEls}]
				       ++ TypedTail;
				 StreamTail ->
				     [check_default_xmlns(OEl)
				      || {xmlstreamelement, OEl} <- StreamTail]
			       end,
		      {200, ?HEADER,
		       jiffy:encode(xmpp_json:to_json(#xmlel{name =
								      <<"body">>,
								  attrs =
								      [{<<"xmlns">>,
									?NS_HTTP_BIND}],
								  children =
								      OutEls}))};
		  _ ->
		      SErrCond = lists:filter(fun ({xmlstreamelement,
						    #xmlel{name =
							       <<"stream:error">>}}) ->
						      true;
						  (_) -> false
					      end,
					      OutPacket),
		      StreamErrCond = case SErrCond of
					[] -> null;
					[{xmlstreamelement,
					  #xmlel{} = StreamErrorTag}
					 | _] ->
					    [StreamErrorTag]
				      end,
		      gen_fsm:sync_send_all_state_event(FsmRef,
							{stop,
							 {stream_error,
							  OutPacket}}),
		      case StreamErrCond of
			null ->
			    {200, ?HEADER,
			     <<"{\"body\" : {\"\"type\"\":\"terminate\", "
			       "\"condition\":\"internal-server-error\", "
			       "\"xmlns\"=\"",
			       (?NS_HTTP_BIND)/binary, "\"}}">>};
			_ ->
			    {200, ?HEADER,
			     <<"{\"body\" : {\"\"type\"\":\"terminate\", "
			       "\"condition\":\"remote-stream-error\", "
			       "\"xmlns\":\"",
			       (?NS_HTTP_BIND)/binary, "\", ",
			       "\"xmlns:stream\":\"", (?NS_STREAM)/binary,
			       "\" \"$\":",
			       (elements_to_string(StreamErrCond))/binary,
			       "}}">>}
		      end
		end
	  end
    end.

parse_request(Data, PayloadSize, MaxStanzaSize) ->
    ?DEBUG("--- incoming data --- ~n~p~n --- END "
	   "--- ",
	   [xmpp_json:from_json(jiffy:decode(Data))]),
    case xmpp_json:from_json(jiffy:decode(Data)) of
      {xmlstreamelement,
       #xmlel{name = <<"body">>, attrs = Attrs,
	      children = Els}} ->
	  Xmlns = xml:get_attr_s(<<"xmlns">>, Attrs),
	  if Xmlns /= (?NS_HTTP_BIND) -> {error, bad_request};
	     true ->
		 case catch
			jlib:binary_to_integer(xml:get_attr_s(<<"rid">>,
								Attrs))
		     of
		   {'EXIT', _} -> {error, bad_request};
		   Rid ->
		       FixedEls = lists:filter(fun (I) ->
						       case I of
							 #xmlel{} -> true;
							 _ -> false
						       end
					       end,
					       Els),
		       Sid = xml:get_attr_s(<<"sid">>, Attrs),
		       if PayloadSize =< MaxStanzaSize ->
			      {ok, {Sid, Rid, Attrs, FixedEls}};
			  true -> {size_limit, Sid}
		       end
		 end
	  end;
      _ -> {error, bad_request}
    end.

send_receiver_reply(undefined, _Reply) -> ok;
send_receiver_reply(Receiver, Reply) ->
    gen_fsm:reply(Receiver, Reply).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive {timeout, Timer, _} -> ok after 0 -> ok end.

set_inactivity_timer(Pause, _MaxInactivity)
    when Pause > 0 ->
    erlang:start_timer(Pause * 1000, self(), []);
%% Otherwise, we apply the max_inactivity value as inactivity timer:
set_inactivity_timer(_Pause, MaxInactivity) ->
    erlang:start_timer(MaxInactivity, self(), []).

elements_to_string([], Acc) ->
    iolist_to_binary(Acc);
elements_to_string([El|Els], Acc) ->
    elements_to_string(Els, [Acc, jiffy:encode(xmpp_json:to_json(El))]).

elements_to_string(Els) ->
    elements_to_string(Els, []).

get_max_inactivity({Host, _}, Default) ->
    case gen_mod:get_module_opt(Host, mod_http_bind, max_inactivity,
                                fun(I) when is_integer(I), I>0 -> I end,
                                undefined)
	of
      Seconds when is_integer(Seconds) -> Seconds * 1000;
      undefined -> Default
    end;
get_max_inactivity(_, Default) -> Default.

get_max_pause({Host, _}) ->
    gen_mod:get_module_opt(Host, mod_http_bind, max_pause,
                           fun(I) when is_integer(I), I>0 -> I end,
			   ?MAX_PAUSE);
get_max_pause(_) -> ?MAX_PAUSE.

check_default_xmlns(#xmlel{name = Name, attrs = Attrs,
			   children = Els} =
			El) ->
    case xml:get_tag_attr_s(<<"xmlns">>, El) of
      <<"">> ->
	  #xmlel{name = Name,
		 attrs = [{<<"xmlns">>, ?NS_CLIENT} | Attrs],
		 children = Els};
      _ -> El
    end.

check_bind_module(XmppDomain) ->
    case gen_mod:is_loaded(XmppDomain, mod_http_bind) of
      true -> true;
      false ->
	  ?ERROR_MSG("You are trying to use BOSH (HTTP Bind), "
		     "but the module mod_http_bind is not "
		     "started.~nCheck your 'modules' section "
		     "in your ejabberd configuration file.",
		     []),
	  false
    end.

make_sid() ->
    <<(p1_sha:sha(term_to_binary({p1_time_compat:monotonic_time(), make_ref()})))/binary,
      "-", (ejabberd_cluster:node_id())/binary>>.

get_session(SID) ->
    case str:tokens(SID, <<"-">>) of
      [_, NodeID] ->
	  case ejabberd_cluster:get_node_by_id(NodeID) of
	    Node when Node == node() ->
		case mnesia:dirty_read({http_bind, SID}) of
		  [] -> {error, enoent};
		  [Session] -> {ok, Session}
		end;
	    Node ->
		case ejabberd_cluster:call(Node, mnesia, dirty_read,
                                           [{http_bind, SID}]) of
		  [Session] -> {ok, Session};
		  _ -> {error, enoent}
		end
	  end;
      _ -> {error, enoent}
    end.
