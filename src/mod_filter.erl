%%%-------------------------------------------------------------------
%%% File    : mod_filter.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : allow message filtering using regexp on message body
%%% Created : 
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
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
%%%-------------------------------------------------------------------

-module(mod_filter).
-behaviour(gen_mod).

-author('christophe.romain@process-one.net').

% module functions
-export([start/2, stop/1, init/2, update/2, is_loaded/0,
	 loop/5]).

-export([add_regexp/4, add_regexp/3, del_regexp/3,
	 del_regexp/2]).

-export([purge_logs/0, purge_regexps/1, reload/1]).

-export([logged/0, logged/1, rules/0]).

-export([process_local_iq/3]).
-export([filter_packet/1, depends/2, mod_opt_type/1]).


-include("ejabberd.hrl").

-include("jlib.hrl").

-include("logger.hrl").

-record(filter_rule,
	{id, type = <<"filter">>, regexp, binre}).

-record(filter_log, {date, from, to, message}).

-define(TIMEOUT, 5000).

-define(PROCNAME(VH),
	jlib:binary_to_atom(<<VH/binary, "_message_filter">>)).

-define(NS_FILTER, <<"p1:iq:filter">>).

-define(ALLHOSTS, <<"all hosts">>).

start(Host, Opts) ->
    mnesia:create_table(filter_rule,
			[{disc_copies, [node()]}, {type, set},
			 {attributes, record_info(fields, filter_rule)}]),
    mnesia:create_table(filter_log,
			      [{disc_only_copies, [node()]}, {type, bag},
			       {attributes, record_info(fields, filter_log)}]),
    case whereis(?PROCNAME(Host)) of
	undefined -> ok;
	_ ->
	    ejabberd_hooks:delete(filter_packet, ?MODULE,
				  filter_packet, 10),
	    gen_iq_handler:remove_iq_handler(ejabberd_local, Host,
					     ?NS_FILTER),
	    (?PROCNAME(Host)) ! quit
    end,
    ejabberd_hooks:add(filter_packet, ?MODULE,
		       filter_packet, 10),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_FILTER, ?MODULE, process_local_iq,
				  one_queue),
    case whereis(?PROCNAME(Host)) of
	undefined ->
	    register(?PROCNAME(Host),
		     spawn(?MODULE, init, [Host, Opts]));
	_ -> ok
    end,
    case whereis(?PROCNAME((?ALLHOSTS))) of
	undefined -> init_all_hosts_handler();
	_ -> ok
    end.

stop(Host) ->
    ejabberd_hooks:delete(filter_packet, ?MODULE,
			  filter_packet, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host,
				     ?NS_FILTER),
    exit(whereis(?PROCNAME(Host)), kill),
    {wait, ?PROCNAME(Host)}.

is_loaded() -> ok.

load_rules(Host) ->
    Rules = mnesia:dirty_match_object(#filter_rule{id =
						       {'_', Host},
						   _ = '_'})
	      ++
	      mnesia:dirty_match_object(#filter_rule{id =
							 {'_', ?ALLHOSTS},
						     _ = '_'}),
    lists:map(fun ({filter_rule, _, Type, _, BinRegExp}) ->
		      {Type, BinRegExp}
	      end,
	      Rules).

init(Host, Opts) ->
    Rules = load_rules(Host),
    Scope = gen_mod:get_opt(scope, Opts,
                            fun(A) when is_atom(A) -> A end,
                            message),
    Pattern = gen_mod:get_opt(pattern, Opts,
                              fun(A) when is_binary(A) -> A end,
                              <<"">>),
    (?MODULE):loop(Host, Opts, Rules, Scope, Pattern).

init_all_hosts_handler() ->
    register(?PROCNAME((?ALLHOSTS)),
	     spawn(?MODULE, loop, [?ALLHOSTS, [], [], none, []])).

update(?ALLHOSTS, _Opts) ->
    lists:foreach(fun (Host) ->
			  lists:foreach(fun (Node) ->
						catch rpc:call(Node, mod_filter,
							       reload, [Host])
					end,
					mnesia:system_info(running_db_nodes))
		  end,
		  ejabberd_config:get_global_option(hosts,
						    fun (V) -> V end)),
    (?MODULE):loop(?ALLHOSTS, [], [], none, []);
update(Host, Opts) ->
    lists:foreach(fun (Node) ->
			  catch rpc:call(Node, mod_filter, reload, [Host])
		  end,
		  mnesia:system_info(running_db_nodes) -- [node()]),
    init(Host, Opts).

loop(Host, Opts, Rules, Scope, Pattern) ->
    receive
      {add, Id, RegExp, Type} ->
	    case re:compile(RegExp, [caseless, dotall]) of
		 {ok, BinRegExp} ->
		    ?INFO_MSG("Adding new filter rule with regexp=~p",
			      [RegExp]),
		    mnesia:dirty_write(#filter_rule{id = {Id, Host},
						    regexp = RegExp,
						    binre = BinRegExp,
						    type = Type}),
		    (?MODULE):update(Host, Opts);
		{error, ErrSpec} ->
		    ?INFO_MSG("Can't add filter rule with regexp=~p "
			      "for id=~p with type=~p. Reason: ~p",
			      [RegExp, Id, Type, ErrSpec]),
		    loop(Host, Opts, Rules, Scope, Pattern)
	    end;
      {del, Id} ->
	  RulesToRemove =
	      mnesia:dirty_match_object(#filter_rule{id = {Id, Host},
						     _ = '_'}),
	  lists:foreach(fun (Rule) ->
				mnesia:dirty_delete_object(Rule)
			end,
			RulesToRemove),
	  (?MODULE):update(Host, Opts);
      {del, Id, RegExp} ->
	  RulesToRemove =
	      mnesia:dirty_match_object(#filter_rule{id = {Id, Host},
						     regexp = RegExp, _ = '_'}),
	  lists:foreach(fun (Rule) ->
				mnesia:dirty_delete_object(Rule)
			end,
			RulesToRemove),
	  (?MODULE):update(Host, Opts);
      {match, From, String} ->
	  From !
	    {match, string_filter(String, Rules, Scope, Pattern)},
	  (?MODULE):loop(Host, Opts, Rules, Scope, Pattern);
      reload -> (?MODULE):init(Host, Opts);
      quit -> unregister(?PROCNAME(Host)), ok
    end.

string_filter(String, Rules, Scope, Pattern) ->
    lists:foldl(fun (_, {Pass, []}) -> {Pass, []};
		    ({Type, RegExp}, {Pass, NewString}) ->
			string_filter(NewString, Pass, RegExp, Type, Scope,
				      Pattern)
		end,
		{<<"pass">>, String}, Rules).

string_filter(String, Pass, RegExp, Type, Scope,
	      Pattern) ->
    %?INFO_MSG("XXX ~p~n", [{String, RegExp, re:run(String, RegExp)}]),
    case re:run(String, RegExp) of
      nomatch -> {Pass, String};
      {match, [{S1, S2}| _]} ->
	  case Scope of
	    word ->
		Start = str:sub_string(String, 1, S1),
		StringTail = str:sub_string(String, S1 + S2 + 1,
					    str:len(String)),
		NewPass = pass_rule(Pass, Type),
		{LastPass, End} = string_filter(StringTail, NewPass,
						RegExp, Type, Scope, Pattern),
		NewString = case Type of
			      <<"log">> ->
				  lists:append([str:sub_string(String, 1, S2),
						End]);
			      _ -> lists:append([Start, Pattern, End])
			    end,
		{LastPass, NewString};
	    _ ->
		NewString = case Type of
			      <<"log">> -> String;
			      _ -> []
			    end,
		{pass_rule(Pass, Type), NewString}
	  end
    end.

pass_rule(<<"pass">>, New) -> New;
pass_rule(<<"log">>, <<"log">>) -> <<"log">>;
pass_rule(<<"log">>, <<"log and filter">>) ->
    <<"log and filter">>;
pass_rule(<<"log">>, <<"filter">>) ->
    <<"log and filter">>;
pass_rule(<<"filter">>, <<"log">>) ->
    <<"log and filter">>;
pass_rule(<<"filter">>, <<"log and filter">>) ->
    <<"log and filter">>;
pass_rule(<<"filter">>, <<"filter">>) -> <<"filter">>;
pass_rule(<<"log and filter">>, _) ->
    <<"log and filter">>.

add_regexp(VH, Id, RegExp) ->
    add_regexp(VH, Id, RegExp, <<"filter">>).

add_regexp(VH, Id, RegExp, Type) ->
    (?PROCNAME(VH)) ! {add, Id, RegExp, Type}, ok.

del_regexp(VH, Id) -> (?PROCNAME(VH)) ! {del, Id}, ok.

del_regexp(VH, Id, RegExp) ->
    (?PROCNAME(VH)) ! {del, Id, RegExp}, ok.

reload(VH) -> (?PROCNAME(VH)) ! reload, ok.

purge_logs() ->
    mnesia:dirty_delete_object(#filter_log{_ = '_'}).

%purge_regexps() ->
%	mnesia:dirty_delete_object(#filter_rule{_='_'}),
%   reload().

purge_regexps(VH) ->
    mnesia:dirty_delete_object(#filter_rule{id = {'_', VH},
					    _ = '_'}),
    reload(VH).

rules() ->
    lists:map(fun (#filter_rule{id = {Label, VH},
				type = Type, regexp = Regexp}) ->
		      {VH, Label, Type, Regexp}
	      end,
	      ets:tab2list(filter_rule)).

logged() ->
    lists:reverse(lists:map(fun (#filter_log{date = Date,
					     from = From, to = To,
					     message = Msg}) ->
				    {Date, jid:to_string(From),
				     jid:to_string(To), Msg}
			    end,
			    ets:tab2list(filter_log))).

logged(Limit) when is_integer(Limit) ->
    List = ets:tab2list(filter_log),
    Len = length(List),
    FinalList = if Len < Limit -> List;
		   true -> lists:nthtail(Len - Limit, List)
		end,
    [{Date, jid:to_string(From), jid:to_string(To), Msg}
	|| #filter_log{date=Date, from=From, to=To, message=Msg}
	    <- lists:reverse(FinalList)].

filter_packet(drop) -> drop;
filter_packet({From, To, Packet}) ->
    case Packet of
      #xmlel{name = <<"message">>, attrs = MsgAttrs,
	     children = Els} ->
	  case lists:keysearch(<<"body">>, 2, Els) of
	    {value,
	     #xmlel{name = <<"body">>, attrs = BodyAttrs,
		    children = Data}} ->
		NewData = lists:foldl(fun ({xmlcdata, CData}, DataAcc)
					      when is_binary(CData) ->
					      #jid{lserver = Host} = To,
					      case lists:member(Host,
								ejabberd_config:get_global_option(hosts,
												  fun
												      (V) ->
													  V
												  end))
						  of
						  true ->
						      Msg = (CData),
						      (?PROCNAME(Host)) !
							  {match, self(), Msg},
						      receive
							  {match,
							   {<<"pass">>, _}} ->
							      [{xmlcdata, CData}
							       | DataAcc];
							  {match, {<<"log">>, _}} ->
							      mnesia:dirty_write(#filter_log{date
											     =
											     erlang:localtime(),
											     from
											     =
											     From,
											     to
											     =
											     To,
											     message
											     =
											     Msg}),
							      [{xmlcdata, CData}
							       | DataAcc];
							  {match,
						       {<<"log and filter">>,
							FinalString}} ->
							  mnesia:dirty_write(#filter_log{date
											     =
											     erlang:localtime(),
											 from
											     =
											     From,
											 to
											     =
											     To,
											 message
											     =
											     Msg}),
							  case FinalString of
							    [] -> % entire message is dropped
								DataAcc;
							    S -> % message must be regenerated
								[{xmlcdata,
								  iolist_to_binary(S)}
								 | DataAcc]
							  end;
						      {match,
						       {<<"filter">>,
							FinalString}} ->
							  case FinalString of
							    [] -> % entire message is dropped
								DataAcc;
							    S -> % message must be regenerated
								[{xmlcdata,
								  iolist_to_binary(S)}
								 | DataAcc]
							  end
						      after ?TIMEOUT ->
								[{xmlcdata,
								  CData}
								 | DataAcc]
						    end;
						false ->
						    [{xmlcdata, CData}
						     | DataAcc]
					      end;
					  (Item,
					   DataAcc) -> %% to not filter internal messages
					      [Item | DataAcc]
				      end,
				      [], Data),
		case NewData of
		  [] -> drop;
		  D ->
		      NewEls = lists:keyreplace(<<"body">>, 2, Els,
						#xmlel{name = <<"body">>,
						       attrs = BodyAttrs,
						       children =
							   lists:reverse(D)}),
		      {From, To,
		       #xmlel{name = <<"message">>, attrs = MsgAttrs,
			      children = NewEls}}
		end;
	    _ -> {From, To, Packet}
	  end;
      _ -> {From, To, Packet}
    end.

process_local_iq(From, #jid{lserver = VH} = _To,
		 #iq{type = Type, sub_el = SubEl} = IQ) ->
    case Type of
      get ->
	  IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
      set ->
	  #jid{luser = User, lserver = Server,
	       lresource = Resource} =
	      From,
	  case acl:match_rule(global, configure,
			      {User, Server, Resource})
	      of
	    allow ->
		case fxml:get_subtag(SubEl, <<"add">>) of
		  #xmlel{name = <<"add">>, attrs = AddAttrs} ->
		      AID = fxml:get_attr_s(<<"id">>, AddAttrs),
		      ARE = fxml:get_attr_s(<<"re">>, AddAttrs),
		      case fxml:get_attr_s(<<"type">>, AddAttrs) of
			<<"">> -> add_regexp(VH, AID, ARE);
			ATP -> add_regexp(VH, AID, ARE, ATP)
		      end;
		  _ -> ok
		end,
		case fxml:get_subtag(SubEl, <<"del">>) of
		  #xmlel{name = <<"del">>, attrs = DelAttrs} ->
		      DID = fxml:get_attr_s(<<"id">>, DelAttrs),
		      case fxml:get_attr_s(<<"re">>, DelAttrs) of
			<<"">> -> del_regexp(VH, DID);
			DRE -> del_regexp(VH, DID, DRE)
		      end;
		  _ -> ok
		end,
		case fxml:get_subtag(SubEl, <<"dellogs">>) of
		  #xmlel{name = <<"dellogs">>} -> purge_logs();
		  _ -> ok
		end,
		case fxml:get_subtag(SubEl, <<"delrules">>) of
		  #xmlel{name = <<"delrules">>} -> purge_regexps(VH);
		  _ -> ok
		end,
		IQ#iq{type = result, sub_el = []};
	    _ ->
		IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
	  end
    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(pattern) ->
    fun (A) when is_binary(A) -> A end;
mod_opt_type(scope) -> fun (A) when is_atom(A) -> A end;
mod_opt_type(_) -> [pattern, scope].
