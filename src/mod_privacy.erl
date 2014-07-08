%%%----------------------------------------------------------------------
%%% File    : mod_privacy.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : jabber:iq:privacy support
%%% Created : 21 Jul 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
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

-module(mod_privacy).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process_iq/3, export/1, import_info/0,
	 process_iq_set/4, process_iq_get/5, get_user_list/3,
	 check_packet/6, remove_user/2, item_to_raw/1,
	 raw_to_item/1, is_list_needdb/1, updated_list/3,
         item_to_xml/1, get_user_lists/2, import/5, import_start/2,
	 enc_key/1, dec_key/1, enc_val/2, dec_val/2,
         p1db_to_items/1, items_to_p1db/1, import_stop/2]).

%% For mod_blocking
-export([sql_add_privacy_list/2,
	 sql_get_default_privacy_list/2,
	 sql_get_default_privacy_list_t/1,
	 sql_get_privacy_list_data/3,
	 sql_get_privacy_list_data_by_id_t/1,
	 sql_get_privacy_list_id_t/2,
	 sql_set_default_privacy_list/2,
	 sql_set_privacy_list/2,
         us_prefix/2, usn2key/3, key2name/2, default_key/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("mod_privacy.hrl").

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
                             one_queue),
    init_db(gen_mod:db_type(Opts), Host),
    mod_disco:register_feature(Host, ?NS_PRIVACY),
    ejabberd_hooks:add(privacy_iq_get, Host, ?MODULE,
		       process_iq_get, 50),
    ejabberd_hooks:add(privacy_iq_set, Host, ?MODULE,
		       process_iq_set, 50),
    ejabberd_hooks:add(privacy_get_user_list, Host, ?MODULE,
		       get_user_list, 50),
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE,
		       check_packet, 50),
    ejabberd_hooks:add(privacy_updated_list, Host, ?MODULE,
		       updated_list, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_PRIVACY, ?MODULE, process_iq, IQDisc).

init_db(mnesia, _Host) ->
    mnesia:create_table(privacy,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, privacy)}]),
    update_table();
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(privacy,
		    [{group, Group},
                     {schema, [{keys, [server, user, name]},
                               {vals, [list]},
                               {enc_key, fun enc_key/1},
                               {dec_key, fun dec_key/1},
                               {enc_val, fun enc_val/2},
                               {dec_val, fun dec_val/2}]}]);
init_db(_, _) ->
    ok.

stop(Host) ->
    mod_disco:unregister_feature(Host, ?NS_PRIVACY),
    ejabberd_hooks:delete(privacy_iq_get, Host, ?MODULE,
			  process_iq_get, 50),
    ejabberd_hooks:delete(privacy_iq_set, Host, ?MODULE,
			  process_iq_set, 50),
    ejabberd_hooks:delete(privacy_get_user_list, Host,
			  ?MODULE, get_user_list, 50),
    ejabberd_hooks:delete(privacy_check_packet, Host,
			  ?MODULE, check_packet, 50),
    ejabberd_hooks:delete(privacy_updated_list, Host,
			  ?MODULE, updated_list, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
				     ?NS_PRIVACY).

process_iq(_From, _To, IQ) ->
    SubEl = IQ#iq.sub_el,
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.

process_iq_get(_, From, _To, #iq{sub_el = SubEl},
	       #userlist{name = Active}) ->
    #jid{luser = LUser, lserver = LServer} = From,
    #xmlel{children = Els} = SubEl,
    case xml:remove_cdata(Els) of
      [] -> process_lists_get(LUser, LServer, Active);
      [#xmlel{name = Name, attrs = Attrs}] ->
	  case Name of
	    <<"list">> ->
		ListName = xml:get_attr(<<"name">>, Attrs),
		process_list_get(LUser, LServer, ListName);
	    _ -> {error, ?ERR_BAD_REQUEST}
	  end;
      _ -> {error, ?ERR_BAD_REQUEST}
    end.

process_lists_get(LUser, LServer, Active) ->
    case process_lists_get(LUser, LServer, Active,
			   gen_mod:db_type(LServer, ?MODULE))
	of
      error -> {error, ?ERR_INTERNAL_SERVER_ERROR};
      {_Default, []} ->
	  {result,
	   [#xmlel{name = <<"query">>,
		   attrs = [{<<"xmlns">>, ?NS_PRIVACY}], children = []}]};
      {Default, LItems} ->
	  DItems = case Default of
		     none -> LItems;
		     _ ->
			 [#xmlel{name = <<"default">>,
				 attrs = [{<<"name">>, Default}], children = []}
			  | LItems]
		   end,
	  ADItems = case Active of
		      none -> DItems;
		      _ ->
			  [#xmlel{name = <<"active">>,
				  attrs = [{<<"name">>, Active}], children = []}
			   | DItems]
		    end,
	  {result,
	   [#xmlel{name = <<"query">>,
		   attrs = [{<<"xmlns">>, ?NS_PRIVACY}],
		   children = ADItems}]}
    end.

process_lists_get(LUser, LServer, _Active, mnesia) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer})
	of
      {'EXIT', _Reason} -> error;
      [] -> {none, []};
      [#privacy{default = Default, lists = Lists}] ->
	  LItems = lists:map(fun ({N, _}) ->
				     #xmlel{name = <<"list">>,
					    attrs = [{<<"name">>, N}],
					    children = []}
			     end,
			     Lists),
	  {Default, LItems}
    end;
process_lists_get(LUser, LServer, _Active, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            DefaultKey = default_key(LUser, LServer),
            lists:foldl(
              fun({Key, Val, _VClock}, {_Def, Els}) when Key == DefaultKey ->
                      {Val, Els};
                 ({Key, _Val, _VClock}, {Def, Els}) ->
                      Name = key2name(USPrefix, Key),
                      {Def, [#xmlel{name = <<"list">>,
                                    attrs = [{<<"name">>, Name}],
                                    children = []}|Els]}
              end, {none, []}, L);
        {error, notfound} ->
            {none, []};
        {error, _} ->
            error
    end;
process_lists_get(LUser, LServer, _Active, riak) ->
    case ejabberd_riak:get(privacy, {LUser, LServer}) of
        {ok, #privacy{default = Default, lists = Lists}} ->
            LItems = lists:map(fun ({N, _}) ->
                                       #xmlel{name = <<"list">>,
                                              attrs = [{<<"name">>, N}],
                                              children = []}
                               end,
                               Lists),
            {Default, LItems};
        {error, notfound} ->
            {none, []};
        {error, _} ->
            error
    end;
process_lists_get(LUser, LServer, _Active, odbc) ->
    Default = case catch sql_get_default_privacy_list(LUser,
						      LServer)
		  of
		{selected, [<<"name">>], []} -> none;
		{selected, [<<"name">>], [[DefName]]} -> DefName;
		_ -> none
	      end,
    case catch sql_get_privacy_list_names(LUser, LServer) of
      {selected, [<<"name">>], Names} ->
	  LItems = lists:map(fun ([N]) ->
				     #xmlel{name = <<"list">>,
					    attrs = [{<<"name">>, N}],
					    children = []}
			     end,
			     Names),
	  {Default, LItems};
      _ -> error
    end.

process_list_get(LUser, LServer, {value, Name}) ->
    case process_list_get(LUser, LServer, Name,
			  gen_mod:db_type(LServer, ?MODULE))
	of
      error -> {error, ?ERR_INTERNAL_SERVER_ERROR};
      not_found -> {error, ?ERR_ITEM_NOT_FOUND};
      Items ->
	  LItems = lists:map(fun item_to_xml/1, Items),
	  {result,
	   [#xmlel{name = <<"query">>,
		   attrs = [{<<"xmlns">>, ?NS_PRIVACY}],
		   children =
		       [#xmlel{name = <<"list">>, attrs = [{<<"name">>, Name}],
			       children = LItems}]}]}
    end;
process_list_get(_LUser, _LServer, false) ->
    {error, ?ERR_BAD_REQUEST}.

process_list_get(LUser, LServer, Name, mnesia) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer})
	of
      {'EXIT', _Reason} -> error;
      [] -> not_found;
      [#privacy{lists = Lists}] ->
	  case lists:keysearch(Name, 1, Lists) of
	    {value, {_, List}} -> List;
	    _ -> not_found
	  end
    end;
process_list_get(LUser, LServer, Name, p1db) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, Val, _VClock} ->
            p1db_to_items(Val);
        {error, notfound} ->
            not_found;
        {error, _} ->
            error
    end;
process_list_get(LUser, LServer, Name, riak) ->
    case ejabberd_riak:get(privacy, {LUser, LServer}) of
        {ok, #privacy{lists = Lists}} ->
            case lists:keysearch(Name, 1, Lists) of
                {value, {_, List}} -> List;
                _ -> not_found
            end;
        {error, notfound} ->
            not_found;
        {error, _} ->
            error
    end;
process_list_get(LUser, LServer, Name, odbc) ->
    case catch sql_get_privacy_list_id(LUser, LServer, Name)
	of
      {selected, [<<"id">>], []} -> not_found;
      {selected, [<<"id">>], [[ID]]} ->
	  case catch sql_get_privacy_list_data_by_id(ID, LServer)
	      of
	    {selected,
	     [<<"t">>, <<"value">>, <<"action">>, <<"ord">>,
	      <<"match_all">>, <<"match_iq">>, <<"match_message">>,
	      <<"match_presence_in">>, <<"match_presence_out">>],
	     RItems} ->
		lists:flatmap(fun raw_to_item/1, RItems);
	    _ -> error
	  end;
      _ -> error
    end.

item_to_xml(Item) ->
    Attrs1 = [{<<"action">>,
	       action_to_list(Item#listitem.action)},
	      {<<"order">>, order_to_list(Item#listitem.order)}],
    Attrs2 = case Item#listitem.type of
	       none -> Attrs1;
	       Type ->
		   [{<<"type">>, type_to_list(Item#listitem.type)},
		    {<<"value">>, value_to_list(Type, Item#listitem.value)}
		    | Attrs1]
	     end,
    SubEls = case Item#listitem.match_all of
	       true -> [];
	       false ->
		   SE1 = case Item#listitem.match_iq of
			   true ->
			       [#xmlel{name = <<"iq">>, attrs = [],
				       children = []}];
			   false -> []
			 end,
		   SE2 = case Item#listitem.match_message of
			   true ->
			       [#xmlel{name = <<"message">>, attrs = [],
				       children = []}
				| SE1];
			   false -> SE1
			 end,
		   SE3 = case Item#listitem.match_presence_in of
			   true ->
			       [#xmlel{name = <<"presence-in">>, attrs = [],
				       children = []}
				| SE2];
			   false -> SE2
			 end,
		   SE4 = case Item#listitem.match_presence_out of
			   true ->
			       [#xmlel{name = <<"presence-out">>, attrs = [],
				       children = []}
				| SE3];
			   false -> SE3
			 end,
		   SE4
	     end,
    #xmlel{name = <<"item">>, attrs = Attrs2,
	   children = SubEls}.

action_to_list(Action) ->
    case Action of
      allow -> <<"allow">>;
      deny -> <<"deny">>
    end.

order_to_list(Order) ->
    iolist_to_binary(integer_to_list(Order)).

type_to_list(Type) ->
    case Type of
      jid -> <<"jid">>;
      group -> <<"group">>;
      subscription -> <<"subscription">>
    end.

value_to_list(Type, Val) ->
    case Type of
      jid -> jlib:jid_to_string(Val);
      group -> Val;
      subscription ->
	  case Val of
	    both -> <<"both">>;
	    to -> <<"to">>;
	    from -> <<"from">>;
	    none -> <<"none">>
	  end
    end.

list_to_action(S) ->
    case S of
      <<"allow">> -> allow;
      <<"deny">> -> deny
    end.

process_iq_set(_, From, _To, #iq{sub_el = SubEl}) ->
    #jid{luser = LUser, lserver = LServer} = From,
    #xmlel{children = Els} = SubEl,
    case xml:remove_cdata(Els) of
      [#xmlel{name = Name, attrs = Attrs,
	      children = SubEls}] ->
	  ListName = xml:get_attr(<<"name">>, Attrs),
	  case Name of
	    <<"list">> ->
		process_list_set(LUser, LServer, ListName,
				 xml:remove_cdata(SubEls));
	    <<"active">> ->
		process_active_set(LUser, LServer, ListName);
	    <<"default">> ->
		process_default_set(LUser, LServer, ListName);
	    _ -> {error, ?ERR_BAD_REQUEST}
	  end;
      _ -> {error, ?ERR_BAD_REQUEST}
    end.

process_default_set(LUser, LServer, Value) ->
    case process_default_set(LUser, LServer, Value,
			     gen_mod:db_type(LServer, ?MODULE))
	of
      {atomic, error} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
      {atomic, not_found} -> {error, ?ERR_ITEM_NOT_FOUND};
      {atomic, ok} -> {result, []};
      _ -> {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.

process_default_set(LUser, LServer, {value, Name},
		    mnesia) ->
    F = fun () ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		  [] -> not_found;
		  [#privacy{lists = Lists} = P] ->
		      case lists:keymember(Name, 1, Lists) of
			true ->
			    mnesia:write(P#privacy{default = Name,
						   lists = Lists}),
			    ok;
			false -> not_found
		      end
		end
	end,
    mnesia:transaction(F);
process_default_set(LUser, LServer, {value, Name}, p1db) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, _Val, _VClock} ->
            DefaultKey = default_key(LUser, LServer),
            case p1db:insert(privacy, DefaultKey, Name) of
                ok -> {atomic, ok};
                {error, _} = Err -> {aborted, Err}
            end;
        {error, notfound} ->
            {atomic, not_found};
        {error, _} = Err ->
            {aborted, Err}
    end;
process_default_set(LUser, LServer, {value, Name}, riak) ->
    {atomic,
     case ejabberd_riak:get(privacy, {LUser, LServer}) of
         {ok, #privacy{lists = Lists} = P} ->
             case lists:keymember(Name, 1, Lists) of
                 true ->
                     ejabberd_riak:put(P#privacy{default = Name,
                                                 lists = Lists});
                 false ->
                     not_found
             end;
         {error, _} ->
             not_found
     end};
process_default_set(LUser, LServer, {value, Name},
		    odbc) ->
    F = fun () ->
		case sql_get_privacy_list_names_t(LUser) of
		  {selected, [<<"name">>], []} -> not_found;
		  {selected, [<<"name">>], Names} ->
		      case lists:member([Name], Names) of
			true -> sql_set_default_privacy_list(LUser, Name), ok;
			false -> not_found
		      end
		end
	end,
    odbc_queries:sql_transaction(LServer, F);
process_default_set(LUser, LServer, false, mnesia) ->
    F = fun () ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		  [] -> ok;
		  [R] -> mnesia:write(R#privacy{default = none})
		end
	end,
    mnesia:transaction(F);
process_default_set(LUser, LServer, false, p1db) ->
    DefaultKey = default_key(LUser, LServer),
    case p1db:delete(privacy, DefaultKey) of
        ok -> {atomic, ok};
        {error, notfound} -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end;
process_default_set(LUser, LServer, false, riak) ->
    {atomic,
     case ejabberd_riak:get(privacy, {LUser, LServer}) of
         {ok, R} ->
             ejabberd_riak:put(R#privacy{default = none});
         {error, _} ->
             ok
     end};
process_default_set(LUser, LServer, false, odbc) ->
    case catch sql_unset_default_privacy_list(LUser,
					      LServer)
	of
      {'EXIT', _Reason} -> {atomic, error};
      {error, _Reason} -> {atomic, error};
      _ -> {atomic, ok}
    end.

process_active_set(LUser, LServer, {value, Name}) ->
    case process_active_set(LUser, LServer, Name,
			    gen_mod:db_type(LServer, ?MODULE))
	of
      error -> {error, ?ERR_ITEM_NOT_FOUND};
      Items ->
	  NeedDb = is_list_needdb(Items),
	  {result, [],
	   #userlist{name = Name, list = Items, needdb = NeedDb}}
    end;
process_active_set(_LUser, _LServer, false) ->
    {result, [], #userlist{}}.

process_active_set(LUser, LServer, Name, mnesia) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer})
	of
      [] -> error;
      [#privacy{lists = Lists}] ->
	  case lists:keysearch(Name, 1, Lists) of
	    {value, {_, List}} -> List;
	    false -> error
	  end
    end;
process_active_set(LUser, LServer, Name, p1db) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, Val, _VClock} ->
            p1db_to_items(Val);
        {error, _} ->
            error
    end;
process_active_set(LUser, LServer, Name, riak) ->
    case ejabberd_riak:get(privacy, {LUser, LServer}) of
        {ok, #privacy{lists = Lists}} ->
            case lists:keysearch(Name, 1, Lists) of
                {value, {_, List}} -> List;
                false -> error
            end;
        {error, _} ->
            error
    end;
process_active_set(LUser, LServer, Name, odbc) ->
    case catch sql_get_privacy_list_id(LUser, LServer, Name)
	of
      {selected, [<<"id">>], []} -> error;
      {selected, [<<"id">>], [[ID]]} ->
	  case catch sql_get_privacy_list_data_by_id(ID, LServer)
	      of
	    {selected,
	     [<<"t">>, <<"value">>, <<"action">>, <<"ord">>,
	      <<"match_all">>, <<"match_iq">>, <<"match_message">>,
	      <<"match_presence_in">>, <<"match_presence_out">>],
	     RItems} ->
		lists:flatmap(fun raw_to_item/1, RItems);
	    _ -> error
	  end;
      _ -> error
    end.

remove_privacy_list(LUser, LServer, Name, mnesia) ->
    F = fun () ->
		case mnesia:read({privacy, {LUser, LServer}}) of
		  [] -> ok;
		  [#privacy{default = Default, lists = Lists} = P] ->
		      if Name == Default -> conflict;
			 true ->
			     NewLists = lists:keydelete(Name, 1, Lists),
			     mnesia:write(P#privacy{lists = NewLists})
		      end
		end
	end,
    mnesia:transaction(F);
remove_privacy_list(LUser, LServer, Name, p1db) ->
    DefaultKey = default_key(LUser, LServer),
    Default = case p1db:get(privacy, DefaultKey) of
                  {ok, Val, _VClock} -> Val;
                  {error, notfound} -> <<"">>;
                  {error, _} = Err -> Err
              end,
    case Default of
        {error, _} = Err1 ->
            {aborted, Err1};
        Name ->
            {atomic, conflict};
        _ ->
            USNKey = usn2key(LUser, LServer, Name),
            case p1db:delete(privacy, USNKey) of
                ok -> {atomic, ok};
                {error, notfound} -> {atomic, ok};
                {error, _} = Err1 -> {aborted, Err1}
            end
    end;
remove_privacy_list(LUser, LServer, Name, riak) ->
    {atomic,
     case ejabberd_riak:get(privacy, {LUser, LServer}) of
         {ok, #privacy{default = Default, lists = Lists} = P} ->
             if Name == Default ->
                     conflict;
                true ->
                     NewLists = lists:keydelete(Name, 1, Lists),
                     ejabberd_riak:put(P#privacy{lists = NewLists})
             end;
         {error, _} ->
             ok
     end};
remove_privacy_list(LUser, LServer, Name, odbc) ->
    F = fun () ->
		case sql_get_default_privacy_list_t(LUser) of
		  {selected, [<<"name">>], []} ->
		      sql_remove_privacy_list(LUser, Name), ok;
		  {selected, [<<"name">>], [[Default]]} ->
		      if Name == Default -> conflict;
			 true -> sql_remove_privacy_list(LUser, Name), ok
		      end
		end
	end,
    odbc_queries:sql_transaction(LServer, F).

set_privacy_list(LUser, LServer, Name, List, mnesia) ->
    F = fun () ->
		case mnesia:wread({privacy, {LUser, LServer}}) of
		  [] ->
		      NewLists = [{Name, List}],
		      mnesia:write(#privacy{us = {LUser, LServer},
					    lists = NewLists});
		  [#privacy{lists = Lists} = P] ->
		      NewLists1 = lists:keydelete(Name, 1, Lists),
		      NewLists = [{Name, List} | NewLists1],
		      mnesia:write(P#privacy{lists = NewLists})
		end
	end,
    mnesia:transaction(F);
set_privacy_list(LUser, LServer, Name, List, p1db) ->
    USNKey = usn2key(LUser, LServer, Name),
    Val = items_to_p1db(List),
    case p1db:insert(privacy, USNKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end;
set_privacy_list(LUser, LServer, Name, List, riak) ->
    {atomic,
     case ejabberd_riak:get(privacy, {LUser, LServer}) of
         {ok, #privacy{lists = Lists} = P} ->
             NewLists1 = lists:keydelete(Name, 1, Lists),
             NewLists = [{Name, List} | NewLists1],
             ejabberd_riak:put(P#privacy{lists = NewLists});
         {error, _} ->
             NewLists = [{Name, List}],
             ejabberd_riak:put(#privacy{us = {LUser, LServer},
                                        lists = NewLists})
     end};
set_privacy_list(LUser, LServer, Name, List, odbc) ->
    RItems = lists:map(fun item_to_raw/1, List),
    F = fun () ->
		ID = case sql_get_privacy_list_id_t(LUser, Name) of
		       {selected, [<<"id">>], []} ->
			   sql_add_privacy_list(LUser, Name),
			   {selected, [<<"id">>], [[I]]} =
			       sql_get_privacy_list_id_t(LUser, Name),
			   I;
		       {selected, [<<"id">>], [[I]]} -> I
		     end,
		sql_set_privacy_list(ID, RItems),
		ok
	end,
    odbc_queries:sql_transaction(LServer, F).

process_list_set(LUser, LServer, {value, Name}, Els) ->
    case parse_items(Els) of
      false -> {error, ?ERR_BAD_REQUEST};
      remove ->
	  case remove_privacy_list(LUser, LServer, Name,
				   gen_mod:db_type(LServer, ?MODULE))
	      of
	    {atomic, conflict} -> {error, ?ERR_CONFLICT};
	    {atomic, ok} ->
		ejabberd_sm:route(jlib:make_jid(LUser, LServer,
                                                <<"">>),
                                  jlib:make_jid(LUser, LServer, <<"">>),
                                  {broadcast, {privacy_list,
                                               #userlist{name = Name,
                                                         list = []},
                                               Name}}),
		{result, []};
	    _ -> {error, ?ERR_INTERNAL_SERVER_ERROR}
	  end;
      List ->
	  case set_privacy_list(LUser, LServer, Name, List,
				gen_mod:db_type(LServer, ?MODULE))
	      of
	    {atomic, ok} ->
		NeedDb = is_list_needdb(List),
		ejabberd_sm:route(jlib:make_jid(LUser, LServer,
                                                <<"">>),
                                  jlib:make_jid(LUser, LServer, <<"">>),
                                  {broadcast, {privacy_list,
                                               #userlist{name = Name,
                                                         list = List,
                                                         needdb = NeedDb},
                                               Name}}),
		{result, []};
	    _ -> {error, ?ERR_INTERNAL_SERVER_ERROR}
	  end
    end;
process_list_set(_LUser, _LServer, false, _Els) ->
    {error, ?ERR_BAD_REQUEST}.

parse_items([]) -> remove;
parse_items(Els) -> parse_items(Els, []).

parse_items([], Res) ->
    lists:keysort(#listitem.order, Res);
parse_items([#xmlel{name = <<"item">>, attrs = Attrs,
		    children = SubEls}
	     | Els],
	    Res) ->
    Type = xml:get_attr(<<"type">>, Attrs),
    Value = xml:get_attr(<<"value">>, Attrs),
    SAction = xml:get_attr(<<"action">>, Attrs),
    SOrder = xml:get_attr(<<"order">>, Attrs),
    Action = case catch list_to_action(element(2, SAction))
		 of
	       {'EXIT', _} -> false;
	       Val -> Val
	     end,
    Order = case catch jlib:binary_to_integer(element(2,
							SOrder))
		of
	      {'EXIT', _} -> false;
	      IntVal ->
		  if IntVal >= 0 -> IntVal;
		     true -> false
		  end
	    end,
    if (Action /= false) and (Order /= false) ->
	   I1 = #listitem{action = Action, order = Order},
	   I2 = case {Type, Value} of
		  {{value, T}, {value, V}} ->
		      case T of
			<<"jid">> ->
			    case jlib:string_to_jid(V) of
			      error -> false;
			      JID ->
				  I1#listitem{type = jid,
					      value = jlib:jid_tolower(JID)}
			    end;
			<<"group">> -> I1#listitem{type = group, value = V};
			<<"subscription">> ->
			    case V of
			      <<"none">> ->
				  I1#listitem{type = subscription,
					      value = none};
			      <<"both">> ->
				  I1#listitem{type = subscription,
					      value = both};
			      <<"from">> ->
				  I1#listitem{type = subscription,
					      value = from};
			      <<"to">> ->
				  I1#listitem{type = subscription, value = to};
			      _ -> false
			    end
		      end;
		  {{value, _}, false} -> false;
		  _ -> I1
		end,
	   case I2 of
	     false -> false;
	     _ ->
		 case parse_matches(I2, xml:remove_cdata(SubEls)) of
		   false -> false;
		   I3 -> parse_items(Els, [I3 | Res])
		 end
	   end;
       true -> false
    end;
parse_items(_, _Res) -> false.

parse_matches(Item, []) ->
    Item#listitem{match_all = true};
parse_matches(Item, Els) -> parse_matches1(Item, Els).

parse_matches1(Item, []) -> Item;
parse_matches1(Item,
	       [#xmlel{name = <<"message">>} | Els]) ->
    parse_matches1(Item#listitem{match_message = true},
		   Els);
parse_matches1(Item, [#xmlel{name = <<"iq">>} | Els]) ->
    parse_matches1(Item#listitem{match_iq = true}, Els);
parse_matches1(Item,
	       [#xmlel{name = <<"presence-in">>} | Els]) ->
    parse_matches1(Item#listitem{match_presence_in = true},
		   Els);
parse_matches1(Item,
	       [#xmlel{name = <<"presence-out">>} | Els]) ->
    parse_matches1(Item#listitem{match_presence_out = true},
		   Els);
parse_matches1(_Item, [#xmlel{} | _Els]) -> false.

is_list_needdb(Items) ->
    lists:any(fun (X) ->
		      case X#listitem.type of
			subscription -> true;
			group -> true;
			_ -> false
		      end
	      end,
	      Items).

get_user_list(Acc, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    {Default, Items} = get_user_list(Acc, LUser, LServer,
				     gen_mod:db_type(LServer, ?MODULE)),
    NeedDb = is_list_needdb(Items),
    #userlist{name = Default, list = Items,
	      needdb = NeedDb}.

get_user_list(_, LUser, LServer, mnesia) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer})
	of
      [] -> {none, []};
      [#privacy{default = Default, lists = Lists}] ->
	  case Default of
	    none -> {none, []};
	    _ ->
		case lists:keysearch(Default, 1, Lists) of
		  {value, {_, List}} -> {Default, List};
		  _ -> {none, []}
		end
	  end;
      _ -> {none, []}
    end;
get_user_list(_, LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    DefaultKey = default_key(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, [{DefaultKey, Default, _VClock}|L]} ->
            USNKey = usn2key(LUser, LServer, Default),
            case lists:keyfind(USNKey, 1, L) of
                {_, Val, _} ->
                    {Default, p1db_to_items(Val)};
                false ->
                    {none, []}
            end;
        {ok, _} ->
            {none, []};
        {error, _} ->
            {none, []}
    end;
get_user_list(_, LUser, LServer, riak) ->
    case ejabberd_riak:get(privacy, {LUser, LServer}) of
        {ok, #privacy{default = Default, lists = Lists}} ->
            case Default of
                none -> {none, []};
                _ ->
                    case lists:keysearch(Default, 1, Lists) of
                        {value, {_, List}} -> {Default, List};
                        _ -> {none, []}
                    end
            end;
        {error, _} ->
            {none, []}
    end;
get_user_list(_, LUser, LServer, odbc) ->
    case catch sql_get_default_privacy_list(LUser, LServer)
	of
      {selected, [<<"name">>], []} -> {none, []};
      {selected, [<<"name">>], [[Default]]} ->
	  case catch sql_get_privacy_list_data(LUser, LServer,
					       Default)
	      of
	    {selected,
	     [<<"t">>, <<"value">>, <<"action">>, <<"ord">>,
	      <<"match_all">>, <<"match_iq">>, <<"match_message">>,
	      <<"match_presence_in">>, <<"match_presence_out">>],
	     RItems} ->
		{Default, lists:flatmap(fun raw_to_item/1, RItems)};
	    _ -> {none, []}
	  end;
      _ -> {none, []}
    end.

get_user_lists(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    get_user_lists(LUser, LServer, gen_mod:db_type(LServer, ?MODULE)).

get_user_lists(LUser, LServer, mnesia) ->
    case catch mnesia:dirty_read(privacy, {LUser, LServer}) of
        [#privacy{} = P] ->
            {ok, P};
        _ ->
            error
    end;
get_user_lists(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            DefaultKey = default_key(LUser, LServer),
            Privacy = #privacy{us = {LUser, LServer}},
            lists:foldl(
              fun({Key, Val, _VClock}, P) when Key == DefaultKey ->
                      P#privacy{default = Val};
                 ({Key, Val, _VClock}, #privacy{lists = Lists} = P) ->
                      Name = key2name(USPrefix, Key),
                      List = p1db_to_items(Val),
                      P#privacy{lists = [{Name, List}|Lists]}
              end, Privacy, L);
        {error, _} ->
            error
    end;
get_user_lists(LUser, LServer, riak) ->
    case ejabberd_riak:get(privacy, {LUser, LServer}) of
        {ok, #privacy{} = P} ->
            {ok, P};
        {error, _} ->
            error
    end;
get_user_lists(LUser, LServer, odbc) ->
    Default = case catch sql_get_default_privacy_list(LUser, LServer) of
                  {selected, [<<"name">>], []} ->
                      none;
                  {selected, [<<"name">>], [[DefName]]} ->
                      DefName;
                  _ ->
                      none
	      end,
    case catch sql_get_privacy_list_names(LUser, LServer) of
        {selected, [<<"name">>], Names} ->
            Lists =
                lists:flatmap(
                  fun([Name]) ->
                          case catch sql_get_privacy_list_data(
                                       LUser, LServer, Name) of
                              {selected,
                               [<<"t">>, <<"value">>, <<"action">>,
                                <<"ord">>, <<"match_all">>, <<"match_iq">>,
                                <<"match_message">>, <<"match_presence_in">>,
                                <<"match_presence_out">>],
                               RItems} ->
                                  [{Name, lists:flatmap(fun raw_to_item/1, RItems)}];
                              _ ->
                                  []
                          end
                  end, Names),
            {ok, #privacy{default = Default,
                          us = {LUser, LServer},
                          lists = Lists}};
        _ ->
            error
    end.

check_packet(_, _User, _Server, _UserList,
	     {#jid{luser = <<"">>, lserver = Server} = _From,
	      #jid{lserver = Server} = _To, _},
	     in) ->
    allow;
check_packet(_, _User, _Server, _UserList,
	     {#jid{lserver = Server} = _From,
	      #jid{luser = <<"">>, lserver = Server} = _To, _},
	     out) ->
    allow;
check_packet(_, _User, _Server, _UserList,
	     {#jid{luser = User, lserver = Server} = _From,
	      #jid{luser = User, lserver = Server} = _To, _},
	     _Dir) ->
    allow;
check_packet(_, User, Server,
	     #userlist{list = List, needdb = NeedDb},
	     {From, To, #xmlel{name = PName, attrs = Attrs}}, Dir) ->
    case List of
      [] -> allow;
      _ ->
	  PType = case PName of
		    <<"message">> -> message;
		    <<"iq">> -> iq;
		    <<"presence">> ->
			case xml:get_attr_s(<<"type">>, Attrs) of
			  %% notification
			  <<"">> -> presence;
			  <<"unavailable">> -> presence;
			  %% subscribe, subscribed, unsubscribe,
			  %% unsubscribed, error, probe, or other
			  _ -> other
			end
		  end,
	  PType2 = case {PType, Dir} of
		     {message, in} -> message;
		     {iq, in} -> iq;
		     {presence, in} -> presence_in;
		     {presence, out} -> presence_out;
		     {_, _} -> other
		   end,
	  LJID = case Dir of
		   in -> jlib:jid_tolower(From);
		   out -> jlib:jid_tolower(To)
		 end,
	  {Subscription, Groups} = case NeedDb of
				     true ->
					 ejabberd_hooks:run_fold(roster_get_jid_info,
								 jlib:nameprep(Server),
								 {none, []},
								 [User, Server,
								  LJID]);
				     false -> {[], []}
				   end,
	  check_packet_aux(List, PType2, LJID, Subscription,
			   Groups)
    end.

check_packet_aux([], _PType, _JID, _Subscription,
		 _Groups) ->
    allow;
check_packet_aux([Item | List], PType, JID,
		 Subscription, Groups) ->
    #listitem{type = Type, value = Value, action = Action} =
	Item,
    case is_ptype_match(Item, PType) of
      true ->
	  case Type of
	    none -> Action;
	    _ ->
		case is_type_match(Type, Value, JID, Subscription,
				   Groups)
		    of
		  true -> Action;
		  false ->
		      check_packet_aux(List, PType, JID, Subscription, Groups)
		end
	  end;
      false ->
	  check_packet_aux(List, PType, JID, Subscription, Groups)
    end.

is_ptype_match(Item, PType) ->
    case Item#listitem.match_all of
      true -> true;
      false ->
	  case PType of
	    message -> Item#listitem.match_message;
	    iq -> Item#listitem.match_iq;
	    presence_in -> Item#listitem.match_presence_in;
	    presence_out -> Item#listitem.match_presence_out;
	    other -> false
	  end
    end.

is_type_match(Type, Value, JID, Subscription, Groups) ->
    case Type of
      jid ->
	  case Value of
	    {<<"">>, Server, <<"">>} ->
		case JID of
		  {_, Server, _} -> true;
		  _ -> false
		end;
	    {User, Server, <<"">>} ->
		case JID of
		  {User, Server, _} -> true;
		  _ -> false
		end;
	    _ -> Value == JID
	  end;
      subscription -> Value == Subscription;
      group -> lists:member(Value, Groups)
    end.

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    F = fun () -> mnesia:delete({privacy, {LUser, LServer}})
	end,
    mnesia:transaction(F);
remove_user(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _, _}) ->
                      p1db:async_delete(privacy, Key)
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
remove_user(LUser, LServer, riak) ->
    {atomic, ejabberd_riak:delete(privacy, {LUser, LServer})};
remove_user(LUser, LServer, odbc) ->
    sql_del_privacy_lists(LUser, LServer).

updated_list(_, #userlist{name = OldName} = Old,
	     #userlist{name = NewName} = New) ->
    if OldName == NewName -> New;
       true -> Old
    end.

us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

usn2key(LUser, LServer, Name) ->
    <<LServer/binary, 0, LUser/binary, 0, Name/binary>>.

default_key(LUser, LServer) ->
    usn2key(LUser, LServer, <<0>>).

key2name(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, Name/binary>> = Key,
    Name.

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, null]) ->
    <<Server/binary, 0, User/binary, 0, 0>>;
enc_key([Server, User, Name]) ->
    <<Server/binary, 0, User/binary, 0, Name/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, Rest/binary>> = UKey,
    case Rest of
        <<0>> ->
            [Server, User, null];
        Name ->
            [Server, User, Name]
    end.

enc_val([_, _, null], [Bin]) ->
    Bin;
enc_val(_, [Expr]) ->
    Term = jlib:expr_to_term(Expr),
    term_to_binary(Term).

dec_val([_, _, null], Bin) ->
    [Bin];
dec_val(_, Bin) ->
    Term = binary_to_term(Bin),
    [jlib:term_to_expr(Term)].

p1db_to_items(Val) ->
    lists:map(fun proplist_to_item/1, binary_to_term(Val)).

items_to_p1db(Items) ->
    term_to_binary(lists:map(fun item_to_proplist/1, Items)).

proplist_to_item(PropList) ->
    lists:foldl(
      fun({type, V}, I) -> I#listitem{type = V};
         ({value, V}, I) -> I#listitem{value = V};
         ({action, V}, I) -> I#listitem{action = V};
         ({order, V}, I) -> I#listitem{order = V};
         ({match_all, V}, I) -> I#listitem{match_all = V};
         ({match_iq, V}, I) -> I#listitem{match_iq = V};
         ({match_message, V}, I) -> I#listitem{match_message = V};
         ({match_presence_in, V}, I) -> I#listitem{match_presence_in = V};
         ({match_presence_out, V}, I) -> I#listitem{match_presence_out = V};
         (_, I) -> I
      end, #listitem{}, PropList).

item_to_proplist(Item) ->
    Keys = record_info(fields, listitem),
    DefItem = #listitem{},
    {_, PropList} =
        lists:foldl(
          fun(Key, {Pos, L}) ->
                  Val = element(Pos, Item),
                  DefVal = element(Pos, DefItem),
                  if Val == DefVal ->
                          {Pos+1, L};
                     true ->
                          {Pos+1, [{Key, Val}|L]}
                  end
          end, {2, []}, Keys),
    PropList.

raw_to_item([SType, SValue, SAction, SOrder, SMatchAll,
	     SMatchIQ, SMatchMessage, SMatchPresenceIn,
	     SMatchPresenceOut] = Row) ->
    try
        {Type, Value} = case SType of
                            <<"n">> -> {none, none};
                            <<"j">> ->
                                case jlib:string_to_jid(SValue) of
                                    #jid{} = JID ->
                                        {jid, jlib:jid_tolower(JID)}
                                end;
                            <<"g">> -> {group, SValue};
                            <<"s">> ->
                                case SValue of
                                    <<"none">> -> {subscription, none};
                                    <<"both">> -> {subscription, both};
                                    <<"from">> -> {subscription, from};
                                    <<"to">> -> {subscription, to}
                                end
                        end,
        Action = case SAction of
                     <<"a">> -> allow;
                     <<"d">> -> deny
                 end,
        Order = jlib:binary_to_integer(SOrder),
        MatchAll = ejabberd_odbc:to_bool(SMatchAll),
        MatchIQ = ejabberd_odbc:to_bool(SMatchIQ),
        MatchMessage = ejabberd_odbc:to_bool(SMatchMessage),
        MatchPresenceIn = ejabberd_odbc:to_bool(SMatchPresenceIn),
        MatchPresenceOut = ejabberd_odbc:to_bool(SMatchPresenceOut),
        [#listitem{type = Type, value = Value, action = Action,
                   order = Order, match_all = MatchAll, match_iq = MatchIQ,
                   match_message = MatchMessage,
                   match_presence_in = MatchPresenceIn,
                   match_presence_out = MatchPresenceOut}]
    catch _:_ ->
            ?WARNING_MSG("failed to parse row: ~p", [Row]),
            []
    end.

item_to_raw(#listitem{type = Type, value = Value,
		      action = Action, order = Order, match_all = MatchAll,
		      match_iq = MatchIQ, match_message = MatchMessage,
		      match_presence_in = MatchPresenceIn,
		      match_presence_out = MatchPresenceOut}) ->
    {SType, SValue} = case Type of
			none -> {<<"n">>, <<"">>};
			jid ->
			    {<<"j">>,
			     ejabberd_odbc:escape(jlib:jid_to_string(Value))};
			group -> {<<"g">>, ejabberd_odbc:escape(Value)};
			subscription ->
			    case Value of
			      none -> {<<"s">>, <<"none">>};
			      both -> {<<"s">>, <<"both">>};
			      from -> {<<"s">>, <<"from">>};
			      to -> {<<"s">>, <<"to">>}
			    end
		      end,
    SAction = case Action of
		allow -> <<"a">>;
		deny -> <<"d">>
	      end,
    SOrder = iolist_to_binary(integer_to_list(Order)),
    SMatchAll = if MatchAll -> <<"1">>;
		   true -> <<"0">>
		end,
    SMatchIQ = if MatchIQ -> <<"1">>;
		  true -> <<"0">>
	       end,
    SMatchMessage = if MatchMessage -> <<"1">>;
		       true -> <<"0">>
		    end,
    SMatchPresenceIn = if MatchPresenceIn -> <<"1">>;
			  true -> <<"0">>
		       end,
    SMatchPresenceOut = if MatchPresenceOut -> <<"1">>;
			   true -> <<"0">>
			end,
    [SType, SValue, SAction, SOrder, SMatchAll, SMatchIQ,
     SMatchMessage, SMatchPresenceIn, SMatchPresenceOut].

sql_get_default_privacy_list(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:get_default_privacy_list(LServer,
					  Username).

sql_get_default_privacy_list_t(LUser) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:get_default_privacy_list_t(Username).

sql_get_privacy_list_names(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:get_privacy_list_names(LServer, Username).

sql_get_privacy_list_names_t(LUser) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:get_privacy_list_names_t(Username).

sql_get_privacy_list_id(LUser, LServer, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:get_privacy_list_id(LServer, Username,
				     SName).

sql_get_privacy_list_id_t(LUser, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:get_privacy_list_id_t(Username, SName).

sql_get_privacy_list_data(LUser, LServer, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:get_privacy_list_data(LServer, Username,
				       SName).

sql_get_privacy_list_data_by_id(ID, LServer) ->
    odbc_queries:get_privacy_list_data_by_id(LServer, ID).

sql_get_privacy_list_data_by_id_t(ID) ->
    odbc_queries:get_privacy_list_data_by_id_t(ID).

sql_set_default_privacy_list(LUser, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:set_default_privacy_list(Username, SName).

sql_unset_default_privacy_list(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:unset_default_privacy_list(LServer,
					    Username).

sql_remove_privacy_list(LUser, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:remove_privacy_list(Username, SName).

sql_add_privacy_list(LUser, Name) ->
    Username = ejabberd_odbc:escape(LUser),
    SName = ejabberd_odbc:escape(Name),
    odbc_queries:add_privacy_list(Username, SName).

sql_set_privacy_list(ID, RItems) ->
    odbc_queries:set_privacy_list(ID, RItems).

sql_del_privacy_lists(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    Server = ejabberd_odbc:escape(LServer),
    odbc_queries:del_privacy_lists(LServer, Server,
				   Username).

update_table() ->
    Fields = record_info(fields, privacy),
    case mnesia:table_info(privacy, attributes) of
      Fields ->
          ejabberd_config:convert_table_to_binary(
            privacy, Fields, set,
            fun(#privacy{us = {U, _}}) -> U end,
            fun(#privacy{us = {U, S}, default = Def, lists = Lists} = R) ->
                    NewLists =
                        lists:map(
                          fun({Name, Ls}) ->
                                  NewLs =
                                      lists:map(
                                        fun(#listitem{value = Val} = L) ->
                                                NewVal =
                                                    case Val of
                                                        {LU, LS, LR} ->
                                                            {iolist_to_binary(LU),
                                                             iolist_to_binary(LS),
                                                             iolist_to_binary(LR)};
                                                        none -> none;
                                                        both -> both;
                                                        from -> from;
                                                        to -> to;
                                                        _ -> iolist_to_binary(Val)
                                                    end,
                                                L#listitem{value = NewVal}
                                        end, Ls),
                                  {iolist_to_binary(Name), NewLs}
                          end, Lists),
                    NewDef = case Def of
                                 none -> none;
                                 _ -> iolist_to_binary(Def)
                             end,
                    NewUS = {iolist_to_binary(U), iolist_to_binary(S)},
                    R#privacy{us = NewUS, default = NewDef,
                              lists = NewLists}
            end);
      _ ->
	  ?INFO_MSG("Recreating privacy table", []),
	  mnesia:transform_table(privacy, ignore, Fields)
    end.

export(Server) ->
    case catch ejabberd_odbc:sql_query(jlib:nameprep(Server),
				 [<<"select id from privacy_list order by "
				    "id desc limit 1;">>]) of
        {selected, [<<"id">>], [[I]]} ->
            put(id, jlib:binary_to_integer(I));
        _ ->
            put(id, 0)
    end,
    [{privacy,
      fun(Host, #privacy{us = {LUser, LServer}, lists = Lists,
                         default = Default})
            when LServer == Host ->
              Username = ejabberd_odbc:escape(LUser),
              if Default /= none ->
                      SDefault = ejabberd_odbc:escape(Default),
                      [[<<"delete from privacy_default_list where ">>,
                        <<"username='">>, Username, <<"';">>],
                       [<<"insert into privacy_default_list(username, "
                          "name) ">>,
                        <<"values ('">>, Username, <<"', '">>,
                        SDefault, <<"');">>]];
                 true ->
                      []
              end ++
                  lists:flatmap(
                    fun({Name, List}) ->
                            SName = ejabberd_odbc:escape(Name),
                            RItems = lists:map(fun item_to_raw/1, List),
                            ID = jlib:integer_to_binary(get_id()),
                            [[<<"delete from privacy_list where username='">>,
                              Username, <<"' and name='">>,
                              SName, <<"';">>],
                             [<<"insert into privacy_list(username, "
                                "name, id) values ('">>,
                              Username, <<"', '">>, SName,
                              <<"', '">>, ID, <<"');">>],
                             [<<"delete from privacy_list_data where "
                                "id='">>, ID, <<"';">>]] ++
                                [[<<"insert into privacy_list_data(id, t, "
                                    "value, action, ord, match_all, match_iq, "
                                    "match_message, match_presence_in, "
                                    "match_presence_out) values ('">>,
                                  ID, <<"', '">>, str:join(Items, <<"', '">>),
                                  <<"');">>] || Items <- RItems]
                    end,
                    Lists);
         (_Host, _R) ->
              []
      end}].

get_id() ->
    ID = get(id),
    put(id, ID + 1),
    ID + 1.

numeric_to_binary(<<0, 0, _/binary>>) ->
    <<"0">>;
numeric_to_binary(<<0, _, _:6/binary, T/binary>>) ->
    Res = lists:foldl(
            fun(X, Sum) ->
                    Sum*10000 + X
            end, 0, [X || <<X:16>> <= T]),
    jlib:integer_to_binary(Res).

bool_to_binary(<<0>>) -> <<"0">>;
bool_to_binary(<<1>>) -> <<"1">>.

prepare_list_data(mysql, [ID|Row]) ->
    [jlib:binary_to_integer(ID)|Row];
prepare_list_data(pgsql, [<<ID:64>>,
                          SType, SValue, SAction, SOrder, SMatchAll,
                          SMatchIQ, SMatchMessage, SMatchPresenceIn,
                          SMatchPresenceOut]) ->
    [ID, SType, SValue, SAction,
     numeric_to_binary(SOrder),
     bool_to_binary(SMatchAll),
     bool_to_binary(SMatchIQ),
     bool_to_binary(SMatchMessage),
     bool_to_binary(SMatchPresenceIn),
     bool_to_binary(SMatchPresenceOut)].

prepare_id(mysql, ID) ->
    jlib:binary_to_integer(ID);
prepare_id(pgsql, <<ID:32>>) ->
    ID.

import_info() ->
    [{<<"privacy_default_list">>, 2},
     {<<"privacy_list_data">>, 10},
     {<<"privacy_list">>, 4}].

import_start(_LServer, odbc) ->
    ok;
import_start(LServer, DBType) ->
    ets:new(privacy_default_list_tmp, [private, named_table]),
    ets:new(privacy_list_data_tmp, [private, named_table, bag]),
    ets:new(privacy_list_tmp, [private, named_table, bag,
                               {keypos, #privacy.us}]),
    init_db(DBType, LServer),
    ok.

import(LServer, {odbc, _}, DBType, <<"privacy_default_list">>, [LUser, Name])
  when DBType == riak; DBType == mnesia; DBType == p1db ->
    US = {LUser, LServer},
    ets:insert(privacy_default_list_tmp, {US, Name}),
    ok;
import(LServer, {odbc, SQLType}, DBType, <<"privacy_list_data">>, Row1)
  when DBType == riak; DBType == mnesia; DBType == p1db ->
    [ID|Row] = prepare_list_data(SQLType, Row1),
    case raw_to_item(Row) of
        [Item] ->
            IS = {ID, LServer},
            ets:insert(privacy_list_data_tmp, {IS, Item}),
            ok;
        [] ->
            ok
    end;
import(LServer, {odbc, SQLType}, DBType, <<"privacy_list">>,
       [LUser, Name, ID, _TimeStamp])
  when DBType == riak; DBType == mnesia; DBType == p1db ->
    US = {LUser, LServer},
    IS = {prepare_id(SQLType, ID), LServer},
    Default = case ets:lookup(privacy_default_list_tmp, US) of
                  [{_, Name}] -> Name;
                  _ -> none
              end,
    case [Item || {_, Item} <- ets:lookup(privacy_list_data_tmp, IS)] of
        [_|_] = Items ->
            Privacy = #privacy{us = {LUser, LServer},
                               default = Default,
                               lists = [{Name, Items}]},
            ets:insert(privacy_list_tmp, Privacy),
            ets:delete(privacy_list_data_tmp, IS),
            ok;
        _ ->
            ok
    end;
import(_LServer, {odbc, _}, odbc, _, _) ->
    ok.

import_stop(_LServer, odbc) ->
    ok;
import_stop(_LServer, DBType) ->
    import_next(DBType, ets:first(privacy_list_tmp)),
    ets:delete(privacy_default_list_tmp),
    ets:delete(privacy_list_data_tmp),
    ets:delete(privacy_list_tmp),
    ok.

import_next(_DBType, '$end_of_table') ->
    ok;
import_next(DBType, {LUser, LServer} = US) ->
    [P|_] = Ps = ets:lookup(privacy_list_tmp, US),
    Lists = lists:flatmap(
              fun(#privacy{lists = Lists}) ->
                      Lists
              end, Ps),
    Privacy = P#privacy{lists = Lists},
    case DBType of
        mnesia ->
            mnesia:dirty_write(Privacy);
        riak ->
            ejabberd_riak:put(Privacy);
        odbc ->
            ok;
        p1db ->
            case P#privacy.default of
                none ->
                    ok;
                Default ->
                    DefaultKey = default_key(LUser, LServer),
                    p1db:async_insert(privacy, DefaultKey, Default)
            end,
            lists:foreach(
              fun({Name, List}) ->
                      USNKey = usn2key(LUser, LServer, Name),
                      Val = items_to_p1db(List),
                      p1db:async_insert(privacy, USNKey, Val)
              end, Lists)
    end,
    import_next(DBType, ets:next(privacy_list_tmp, US)).
