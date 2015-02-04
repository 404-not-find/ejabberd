%%%----------------------------------------------------------------------
%%% File    : pubsub_debug.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Provide helpers to debug pubsub server
%%% Created : 16 Sep 2010 by Christophe Romain <christophe.romain@process-one.net>
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

-module(pubsub_debug).

-author('christophe.romain@process-one.net').

-include("pubsub.hrl").

-compile(export_all).

-spec(nodeid/2 ::
      (
        Host :: mod_pubsub:host(),
        Node :: mod_pubsub:nodeId())
      -> mod_pubsub:nodeIdx() | 0
      ).
nodeid(Host, Node) ->
    case mnesia:dirty_read({pubsub_node, {Host, Node}}) of
        [N] -> nodeid(N);
        _ -> 0
    end.

nodeid(N) -> N#pubsub_node.id.

-spec(nodeids/0 :: () -> [0 | mod_pubsub:nodeIdx()]).

nodeids() ->
    [nodeid(Host, Node)
     || {Host, Node} <- mnesia:dirty_all_keys(pubsub_node)].

-spec(nodeids_by_type/1 ::
      (
        Type :: binary())
      -> [0 | mod_pubsub:nodeIdx()]
      ).
nodeids_by_type(Type) ->
    [nodeid(N)
     || N
        <- mnesia:dirty_match_object(#pubsub_node{type = Type, _ = '_'})].

nodeids_by_option(Key, Value) ->
    [nodeid(N)
     || N
        <- mnesia:dirty_match_object(#pubsub_node{_ = '_'}),
        lists:member({Key, Value}, N#pubsub_node.options)].

nodeids_by_owner(JID) ->
    [nodeid(N)
     || N
        <- mnesia:dirty_match_object(#pubsub_node{_ = '_'}),
        lists:member(JID, N#pubsub_node.owners)].

nodes_by_id(I) ->
    mnesia:dirty_match_object(#pubsub_node{id = I, _ = '_'}).

nodes() ->
    [element(2, element(2, N))
     || N
        <- mnesia:dirty_match_object(#pubsub_node{_ = '_'})].

state(JID, NodeId) ->
    case mnesia:dirty_read({pubsub_state, {JID, NodeId}}) of
        [S] -> S;
        _ -> undefined
    end.

states(NodeId) ->
    mnesia:dirty_index_read(pubsub_state, NodeId, #pubsub_state.nodeidx).

stateid(S) -> element(1, S#pubsub_state.stateid).

stateids(NodeId) -> [stateid(S) || S <- states(NodeId)].

states_by_jid(JID) ->
    mnesia:dirty_match_object(#pubsub_state{stateid = {JID, '_'}, _ = '_'}).

item(ItemId, NodeId) ->
    case mnesia:dirty_read({pubsub_item, {ItemId, NodeId}}) of
        [I] -> I;
        _ -> undefined
    end.

items(NodeId) ->
    mnesia:dirty_index_read(pubsub_item, NodeId,
                            #pubsub_item.nodeidx).

itemid(I) -> element(1, I#pubsub_item.itemid).

itemids(NodeId) -> [itemid(I) || I <- items(NodeId)].

items_by_id(ItemId) ->
    mnesia:dirty_match_object(#pubsub_item{itemid = {ItemId, '_'}, _ = '_'}).

affiliated(NodeId) ->
    [stateid(S)
     || S <- states(NodeId),
        S#pubsub_state.affiliation =/= none].

subscribed(NodeId) ->
    [stateid(S)
     || S <- states(NodeId),
        S#pubsub_state.subscriptions =/= []].

offline_subscribers(NodeId) ->
    lists:filter(fun
            ({U, S, <<"">>}) -> ejabberd_sm:get_user_resources(U, S) == [];
            ({U, S, R}) -> not lists:member(R, ejabberd_sm:get_user_resources(U, S))
        end,
        subscribed(NodeId)).


owners(NodeId) ->
    [stateid(S)
     || S <- states(NodeId),
        S#pubsub_state.affiliation == owner].

orphan_items(NodeId) ->
    itemids(NodeId) --
    lists:foldl(fun (S, A) -> A ++ S#pubsub_state.items end,
                [], states(NodeId)).

newer_items(NodeId, Seconds) ->
    Now = calendar:universal_time(),
    Oldest = calendar:seconds_to_daystime(Seconds),
    [itemid(I)
     || I <- items(NodeId),
        calendar:time_difference(calendar:now_to_universal_time(element(1, I#pubsub_item.modification)), Now)
        < Oldest].

older_items(NodeId, Seconds) ->
    Now = calendar:universal_time(),
    Oldest = calendar:seconds_to_daystime(Seconds),
    [itemid(I)
     || I <- items(NodeId),
        calendar:time_difference(calendar:now_to_universal_time(element(1, I#pubsub_item.modification)), Now)
        > Oldest].

orphan_nodes() ->
    [I || I <- nodeids(), owners(I) == []].

duplicated_nodes() ->
    L = nodeids(),
    lists:usort(L -- lists:seq(1, lists:max(L))).

node_options(NodeId) ->
    [N] = mnesia:dirty_match_object(#pubsub_node{id = NodeId, _ = '_'}),
    N#pubsub_node.options.

update_node_options(Key, Value, NodeId) ->
    [N] = mnesia:dirty_match_object(#pubsub_node{id = NodeId, _ = '_'}),
    NewOptions = lists:keyreplace(Key, 1, N#pubsub_node.options, {Key, Value}),
    mnesia:dirty_write(N#pubsub_node{options = NewOptions}).

check() ->
    mnesia:transaction(fun () ->
                case mnesia:read({pubsub_index, node}) of
                    [Idx] ->
                        Free = Idx#pubsub_index.free,
                        Last = Idx#pubsub_index.last,
                        Allocated = lists:seq(1, Last) -- Free,
                        NodeIds = mnesia:foldl(fun (N, A) ->
                                        [nodeid(N) | A]
                                end,
                                [], pubsub_node),
                        StateIds = lists:usort(mnesia:foldl(fun (S, A) ->
                                            [element(2, S#pubsub_state.stateid) | A]
                                    end,
                                    [], pubsub_state)),
                        ItemIds = lists:usort(mnesia:foldl(fun (I, A) ->
                                            [element(2, I#pubsub_item.itemid) | A]
                                    end,
                                    [], pubsub_item)),
                        BadNodeIds = NodeIds -- Allocated,
                        BadStateIds = StateIds -- NodeIds,
                        BadItemIds = ItemIds -- NodeIds,
                        Lost = Allocated -- NodeIds,
                        [{bad_nodes,
                          [N#pubsub_node.nodeid
                           || N <- lists:flatten([mnesia:match_object(#pubsub_node{id = I, _ = '_'})
                                                || I <- BadNodeIds])]},
                         {bad_states,
                          lists:foldl(fun (N, A) ->
                                            A ++ [{I, N} || I <- stateids(N)]
                                    end,
                                    [], BadStateIds)},
                         {bad_items,
                          lists:foldl(fun (N, A) ->
                                            A ++ [{I, N} || I <- itemids(N)]
                                    end,
                                    [], BadItemIds)},
                         {lost_idx, Lost},
                         {orphaned,
                          [I || I <- NodeIds, owners(I) == []]},
                         {duplicated,
                          lists:usort(NodeIds -- lists:seq(1, lists:max(NodeIds)))}];
                    _ ->
                        no_index
                end
        end).

rebuild_index() ->
    mnesia:transaction(fun () ->
                NodeIds = mnesia:foldl(fun (N, A) ->
                                [nodeid(N) | A]
                        end,
                        [], pubsub_node),
                Last = lists:max(NodeIds),
                Free = lists:seq(1, Last) -- NodeIds,
                mnesia:write(#pubsub_index{index = node, last = Last, free = Free})
        end).

pep_subscriptions(LUser, LServer, LResource) ->
    case ejabberd_sm:get_session_pid(LUser, LServer, LResource) of
        C2SPid when is_pid(C2SPid) ->
            case catch ejabberd_c2s:get_subscribed(C2SPid) of
                Contacts when is_list(Contacts) ->
                    lists:map(fun ({U, S, _}) ->
                                io_lib:format("~s@~s", [U, S])
                        end,
                        Contacts);
                _ ->
                    []
            end;
        _ ->
            []
    end.

purge_offline_subscriptions() ->
    lists:foreach(fun (K) ->
                [N] = mnesia:dirty_read({pubsub_node, K}),
                I = element(3, N),
                lists:foreach(fun (JID) ->
                            case mnesia:dirty_read({pubsub_state, {JID, I}}) of
                                [{pubsub_state, K, _, _, _, [{subscribed, S}]}] ->
                                    mnesia:dirty_delete({pubsub_subscription, S});
                                _ ->
                                    ok
                            end,
                            mnesia:dirty_delete({pubsub_state, {JID, I}})
                    end,
                    offline_subscribers(I))
        end,
        mnesia:dirty_all_keys(pubsub_node)).
