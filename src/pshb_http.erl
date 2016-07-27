%%%----------------------------------------------------------------------
%%% File    : pshb_http.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose :
%%% Created :01-09-2010
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
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
%%%
%%%  {5280, ejabberd_http, [
%%%			 http_poll,
%%%			 web_admin,
%%%			 {request_handlers, [{["pshb"], pshb_http}]} % this should be added
%%%			]}
%%%
%%% To post to a node the content of the file "sam.atom" on the "foo", on the localhost virtual host, using cstar@localhost
%%%  curl -u cstar@localhost:encore  -i -X POST  http://localhost:5280/pshb/localhost/foo -d @sam.atom
%%%

-module(pshb_http).

-author('ecestari@process-one.net').

-compile({no_auto_import, [{error, 1}]}).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("pubsub.hrl").

-export([process/2]).

process([_Domain | _Rest] = LocalPath,
	#request{auth = Auth} = Request) ->
    UD = get_auth(Auth),
    case catch out(mod_pubsub, Request, Request#request.method,
		   LocalPath, UD)
	of
      {'EXIT', Error} ->
	  ?ERROR_MSG("Error while processing ~p : ~n~p",
		     [LocalPath, Error]),
	  error(500);
      Result -> Result
    end.

get_auth(Auth) ->
    case Auth of
      {SJID, P} ->
	  case jid:from_string(SJID) of
	    error -> undefined;
	    #jid{user = U, server = S} ->
		case ejabberd_auth:check_password(U, <<"">>, S, P) of
		  true -> {U, S};
		  false -> undefined
		end
	  end;
      _ -> undefined
    end.

out(Module, Args, 'GET', [Domain, Node] = Uri, _User) ->
    case Module:tree_action(get_host(Uri), get_node,
			    [get_host(Uri), get_collection(Uri)])
	of
      {error, Error} -> error(Error);
      #pubsub_node{options = Options} ->
	  AccessModel = lists:keyfind(access_model, 1, Options),
	  case AccessModel of
	    {access_model, open} ->
		Items = lists:sort(fun (X, Y) ->
					   {DateX, _} =
					       X#pubsub_item.modification,
					   {DateY, _} =
					       Y#pubsub_item.modification,
					   DateX > DateY
				   end,
				   Module:get_items(get_host(Uri),
						    get_collection(Uri))),
		case Items of
		  [] ->
		      ?DEBUG("Items : ~p ~n",
			     [collection(get_collection(Uri),
					 collection_uri(Args, Domain, Node),
					 calendar:universal_time(),
					 <<"">>, [])]),
		      {200,
		       [{<<"Content-Type">>, <<"application/atom+xml">>}],
		       collection(get_collection(Uri),
				  collection_uri(Args, Domain, Node),
				  calendar:universal_time(),
				  <<"">>, [])};
		  _ ->
		      #pubsub_item{modification = {LastDate, _JID}} =
			  LastItem = hd(Items),
		      Etag = generate_etag(LastItem),
		      IfNoneMatch = proplists:get_value('If-None-Match',
							Args#request.headers),
		      if IfNoneMatch == Etag -> success(304);
			 true ->
			     XMLEntries = [item_to_entry(Args, Domain, Node,
							 Entry)
					   || Entry <- Items],
			     {200,
			      [{<<"Content-Type">>, <<"application/atom+xml">>},
			       {<<"Etag">>, Etag}],
			      <<"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n",
				(fxml:element_to_binary(collection(get_collection(Uri),
								  collection_uri(Args,
										 Domain,
										 Node),
								  calendar:now_to_universal_time(LastDate),
								  <<"">>,
								  XMLEntries)))/binary>>}
		      end
		end;
	    {access_model, Access} ->
		?INFO_MSG("Uri ~p requested. access_model is ~p. "
			  "HTTP access denied unless access_model "
			  "=:= open",
			  [Uri, Access]),
		error(?ERR_FORBIDDEN)
	  end
    end;
out(Module, Args, 'POST', [_D, _Node] = Uri,
    {_User, _Domain} = UD) ->
    publish_item(Module, Args, Uri, uniqid(false), UD);
out(Module, Args, 'PUT', [_D, _Node, Slug] = Uri,
    {_User, _Domain} = UD) ->
    publish_item(Module, Args, Uri, Slug, UD);
out(Module, _Args, 'DELETE', [_D, Node, Id] = Uri,
    {User, UDomain}) ->
    Jid = jid:make({User, UDomain, <<"">>}),
    case Module:delete_item(get_host(Uri),
			    iolist_to_binary(Node), Jid, Id)
	of
      {error, Error} -> error(Error);
      {result, _Res} -> success(200)
    end;
out(Module, Args, 'PUT', [_Domain, Node] = Uri,
    {User, UDomain}) ->
    Host = get_host(Uri),
    Jid = jid:make({User, UDomain, <<"">>}),
    Payload = fxml_stream:parse_element(Args#request.data),
    ConfigureElement = case fxml:get_subtag(Payload,
					   <<"configure">>)
			   of
			 false -> [];
			 #xmlel{children = SubEls} -> SubEls
		       end,
    case Module:set_configure(Host, iolist_to_binary(Node),
			      Jid, ConfigureElement, Args#request.lang)
	of
      {result, []} -> success(200);
      {error, Error} -> error(Error)
    end;
out(Module, Args, 'GET', [Domain] = Uri, From) ->
    Host = get_host(Uri),
    ?DEBUG("Host = ~p", [Host]),
    case Module:tree_action(Host, get_subnodes,
			    [Host, <<>>, From])
	of
      [] ->
	  ?DEBUG("Error getting URI ~p : ~p", [Uri, From]),
	  error(?ERR_ITEM_NOT_FOUND);
      Collections ->
	  {200,
	   [{<<"Content-Type">>, <<"application/atomsvc+xml">>}],
	   <<"<?xml version=\"1.0\" encoding=\"utf-8\"?>",
	     (fxml:element_to_binary(service(Args, Domain,
					    Collections)))/binary>>}
    end;
out(Module, Args, 'POST', [Domain] = Uri,
    {User, UDomain}) ->
    Host = get_host(Uri),
    Payload = fxml_stream:parse_element(Args#request.data),
    {Node, Type} = case fxml:get_subtag(Payload,
				       <<"create">>)
		       of
		     false -> {<<>>, <<"flat">>};
		     E ->
                           {get_tag_attr_or_default(<<"node">>, E, <<"">>),
                            get_tag_attr_or_default(<<"type">>, E, <<"flat">>)}
		   end,
    ConfigureElement = case fxml:get_subtag(Payload,
					   <<"configure">>)
			   of
			 false -> [];
			 #xmlel{children = SubEls} -> SubEls
		       end,
    Jid = jid:make({User, UDomain, <<"">>}),
    case Module:create_node(Host, Domain, Node, Jid, Type,
			    all, ConfigureElement)
	of
      {error, Error} ->
	  ?ERROR_MSG("Error create node via HTTP : ~p", [Error]),
	  error(Error);
      {result, [Result]} ->
	  {200, [{<<"Content-Type">>, <<"application/xml">>}],
	   <<"<?xml version=\"1.0\" encoding=\"utf-8\"?>",
	     (fxml:element_to_binary(Result))/binary>>}
    end;
out(Module, _Args, 'DELETE', [_Domain, Node] = Uri,
    {User, UDomain}) ->
    Host = get_host(Uri),
    Jid = jid:make({User, UDomain, <<"">>}),
    case Module:delete_node(Host, Node, Jid) of
      {error, Error} -> error(Error);
      {result, _} -> {200, [], []}
    end;
out(Module, Args, 'GET', [Domain, Node, _Item] = URI,
    _) ->
    Failure = fun (Error) ->
		      ?DEBUG("Error getting URI ~p : ~p", [URI, Error]),
		      error(Error)
	      end,
    Success = fun (Item) ->
		      Etag = generate_etag(Item),
		      IfNoneMatch = proplists:get_value('If-None-Match',
							Args#request.headers),
		      if IfNoneMatch == Etag -> success(304);
			 true ->
			     {200,
			      [{<<"Content-Type">>, <<"application/atom+xml">>},
			       {<<"Etag">>, Etag}],
			      <<"<?xml version=\"1.0\" encoding=\"utf-8\"?>",
				(fxml:element_to_binary(item_to_entry(Args,
								     Domain,
								     Node,
								     Item)))/binary>>}
		      end
	      end,
    get_item(Module, URI, Failure, Success);
out(_Module, _, Method, Uri, undefined) ->
    ?DEBUG("Error, ~p  not authorized for ~p : ~p",
	   [Method, Uri]),
    error(?ERR_FORBIDDEN).

get_item(Module, Uri, Failure, Success) ->
    ?DEBUG(" Module:get_item(~p, ~p,~p)",
	   [get_host(Uri), get_collection(Uri), get_member(Uri)]),
    case Module:get_item(get_host(Uri), get_collection(Uri),
			 get_member(Uri))
	of
      {error, Reason} -> Failure(Reason);
      #pubsub_item{} = Item -> Success(Item)
    end.

publish_item(Module, Args, [Domain, Node | _R] = Uri,
	     Slug, {User, Domain}) ->
    Payload = fxml_stream:parse_element(Args#request.data),
    [FilteredPayload] = fxml:remove_cdata([Payload]),
    case Module:publish_item(get_host(Uri), Domain,
			     get_collection(Uri),
			     jid:make(User, Domain, <<"">>), Slug,
			     [FilteredPayload])
	of
      {result, [_]} ->
	  ?DEBUG("Publishing to ~p~n",
		 [entry_uri(Args, Domain, Node, Slug)]),
	  {201,
	   [{<<"location">>, entry_uri(Args, Domain, Node, Slug)}],
	   Payload};
      {error, Error} -> error(Error)
    end.

generate_etag(#pubsub_item{modification =
			       {{_, D2, D3}, _JID}}) ->
    jlib:integer_to_binary(D3 + D2).

get_host([Domain | _Rest]) ->
    <<"pubsub.", Domain/binary>>.

get_collection([_Domain, Node | _Rest]) ->
    Node.

get_member([_Domain, _Node, Member]) -> Member.

collection_uri(R, Domain, Node) ->
    <<(base_uri(R, Domain))/binary, "/",
      Node/binary>>.

entry_uri(R, Domain, Node, Id) ->
    <<(collection_uri(R, Domain, Node))/binary, "/",
      Id/binary>>.

base_uri(#request{host = Host, port = Port}, Domain) ->
    <<"http://", Host/binary, ":", (i2l(Port))/binary,
      "/pshb/", Domain/binary>>.

item_to_entry(Args, Domain, Node,
	      #pubsub_item{itemid = {Id, _}, payload = Entry} =
		  Item) ->
    [R] = fxml:remove_cdata(Entry),
    item_to_entry(Args, Domain, Node, Id, R, Item).

item_to_entry(Args, Domain, Node, Id,
	      #xmlel{name = <<"entry">>, attrs = Attrs,
		     children = SubEl},
	      #pubsub_item{modification = {Secs, JID}}) ->
    Date = calendar:now_to_local_time(Secs),
    {_User, Domain, _} = jid:tolower(JID),
    SubEl2 = [#xmlel{name = <<"app:edited">>, attrs = [],
		     children = [{xmlcdata, w3cdtf(Date)}]},
	      #xmlel{name = <<"updated">>, attrs = [],
		     children = [{xmlcdata, w3cdtf(Date)}]},
	      #xmlel{name = <<"author">>, attrs = [],
		     children =
			 [#xmlel{name = <<"name">>, attrs = [],
				 children =
				     [{xmlcdata,
				       jid:to_string(JID)}]}]},
	      #xmlel{name = <<"link">>,
		     attrs =
			 [{<<"rel">>, <<"edit">>},
			  {<<"href">>, entry_uri(Args, Domain, Node, Id)}],
		     children = []},
	      #xmlel{name = <<"id">>, attrs = [],
		     children =
			 [{xmlcdata, entry_uri(Args, Domain, Node, Id)}]}
	      | SubEl],
    #xmlel{name = <<"entry">>,
	   attrs =
	       [{<<"xmlns:app">>, <<"http://www.w3.org/2007/app">>}
		| Attrs],
	   children = SubEl2};
% Don't do anything except adding xmlns
item_to_entry(_Args, _Domain, Node, _Id,
	      #xmlel{name = Name, attrs = Attrs, children = Subels} =
		  Element,
	      _Item) ->
    case proplists:is_defined(<<"xmlns">>, Attrs) of
      true -> Element;
      false ->
	  #xmlel{name = Name,
		 attrs = [{<<"xmlns">>, Node} | Attrs],
		 children = Subels}
    end.

collection(Title, Link, Updated, _Id, Entries) ->
    #xmlel{name = <<"feed">>,
	   attrs =
	       [{<<"xmlns">>, <<"http://www.w3.org/2005/Atom">>},
		{<<"xmlns:app">>, <<"http://www.w3.org/2007/app">>}],
	   children =
	       [#xmlel{name = <<"title">>, attrs = [],
		       children = [{xmlcdata, Title}]},
		#xmlel{name = <<"generator">>, attrs = [],
		       children = [{xmlcdata, <<"ejabberd">>}]},
		#xmlel{name = <<"updated">>, attrs = [],
		       children = [{xmlcdata, w3cdtf(Updated)}]},
		#xmlel{name = <<"link">>,
		       attrs = [{<<"href">>, Link}, {<<"rel">>, <<"self">>}],
		       children = []},
		#xmlel{name = <<"id">>, attrs = [],
		       children = [{xmlcdata, iolist_to_binary(Link)}]},
		#xmlel{name = <<"title">>, attrs = [],
		       children = [{xmlcdata, Title}]}
		| Entries]}.

service(Args, Domain, Collections) ->
    #xmlel{name = <<"service">>,
	   attrs =
	       [{<<"xmlns">>, <<"http://www.w3.org/2007/app">>},
		{<<"xmlns:atom">>, <<"http://www.w3.org/2005/Atom">>},
		{<<"xmlns:app">>, <<"http://www.w3.org/2007/app">>}],
	   children =
	       [#xmlel{name = <<"workspace">>, attrs = [],
		       children =
			   [#xmlel{name = <<"atom:title">>, attrs = [],
				   children =
				       [{xmlcdata,
					 <<"Pubsub node Feed for ",
					   Domain/binary>>}]}
			    | lists:map(fun (#pubsub_node{nodeid =
							      {_Server, Id},
							  type = _Type}) ->
						#xmlel{name = <<"collection">>,
						       attrs =
							   [{<<"href">>,
							     collection_uri(Args,
									    Domain,
									    Id)}],
						       children =
							   [#xmlel{name =
								       <<"atom:title">>,
								   attrs = [],
								   children =
								       [{xmlcdata,
									 Id}]}]}
					end,
					Collections)]}]}.

error(#xmlel{name = <<"error">>, attrs = Attrs} =
	  Error) ->
    Value =
	jlib:binary_to_integer(fxml:get_attr_s(<<"code">>,
						Attrs)),
    {Value, [{<<"Content-type">>, <<"application/xml">>}],
     fxml:element_to_binary(Error)};
error(404) -> {404, [], <<"Not Found">>};
error(403) -> {403, [], <<"Forbidden">>};
error(500) -> {500, [], <<"Internal server error">>};
error(401) ->
    {401,
     [{<<"WWW-Authenticate">>,
       <<"basic realm=\"ejabberd\"">>}],
     <<"Unauthorized">>};
error(Code) -> {Code, [], <<"">>}.

success(200) -> {200, [], <<"">>};
success(Code) -> {Code, [], <<"">>}.

uniqid(false) ->
    {T1, T2, T3} = p1_time_compat:timestamp(),
    list_to_binary(io_lib:fwrite("~.16B~.16B~.16B",
                                 [T1, T2, T3])).

w3cdtf(Date) -> %1   Date = calendar:gregorian_seconds_to_datetime(GregSecs),
    {{Y, Mo, D}, {H, Mi, S}} = Date,
    [UDate | _] =
	calendar:local_time_to_universal_time_dst(Date),
    {DiffD, {DiffH, DiffMi, _}} =
	calendar:time_difference(UDate, Date),
    w3cdtf_diff(Y, Mo, D, H, Mi, S, DiffD, DiffH, DiffMi).

w3cdtf_diff(Y, Mo, D, H, Mi, S, _DiffD, DiffH, DiffMi)
    when DiffH < 12, DiffH /= 0 ->
    <<(i2l(Y))/binary, "-", (add_zero(Mo))/binary, "-",
      (add_zero(D))/binary, "T", (add_zero(H))/binary, ":",
      (add_zero(Mi))/binary, ":", (add_zero(S))/binary, "+",
      (add_zero(DiffH))/binary, ":",
      (add_zero(DiffMi))/binary>>;
w3cdtf_diff(Y, Mo, D, H, Mi, S, DiffD, DiffH, DiffMi)
    when DiffH > 12, DiffD == 0 ->
    <<(i2l(Y))/binary, "-", (add_zero(Mo))/binary, "-",
      (add_zero(D))/binary, "T", (add_zero(H))/binary, ":",
      (add_zero(Mi))/binary, ":", (add_zero(S))/binary, "+",
      (add_zero(DiffH))/binary, ":",
      (add_zero(DiffMi))/binary>>;
w3cdtf_diff(Y, Mo, D, H, Mi, S, DiffD, DiffH, DiffMi)
    when DiffH > 12, DiffD /= 0, DiffMi /= 0 ->
    <<(i2l(Y))/binary, "-", (add_zero(Mo))/binary, "-",
      (add_zero(D))/binary, "T", (add_zero(H))/binary, ":",
      (add_zero(Mi))/binary, ":", (add_zero(S))/binary, "-",
      (add_zero(23 - DiffH))/binary, ":",
      (add_zero(60 - DiffMi))/binary>>;
w3cdtf_diff(Y, Mo, D, H, Mi, S, DiffD, DiffH, DiffMi)
    when DiffH > 12, DiffD /= 0, DiffMi == 0 ->
    <<(i2l(Y))/binary, "-", (add_zero(Mo))/binary, "-",
      (add_zero(D))/binary, "T", (add_zero(H))/binary, ":",
      (add_zero(Mi))/binary, ":", (add_zero(S))/binary, "-",
      (add_zero(24 - DiffH))/binary, ":",
      (add_zero(DiffMi))/binary>>;
w3cdtf_diff(Y, Mo, D, H, Mi, S, _DiffD, DiffH, _DiffMi)
    when DiffH == 0 ->
    <<(i2l(Y))/binary, "-", (add_zero(Mo))/binary, "-",
      (add_zero(D))/binary, "T", (add_zero(H))/binary, ":",
      (add_zero(Mi))/binary, ":", (add_zero(S))/binary, "Z">>.

add_zero(I) when is_integer(I) -> add_zero(i2l(I));
add_zero(<<A>>) -> <<$0, A>>;
add_zero(L) when is_binary(L) -> L.

i2l(I) when is_integer(I) ->
    jlib:integer_to_binary(I).

get_tag_attr_or_default(AttrName, Element, Default) ->
    case fxml:get_tag_attr_s(AttrName, Element) of
      <<"">> -> Default;
      Val -> Val
    end.
