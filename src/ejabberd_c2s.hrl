%%%----------------------------------------------------------------------
%%%
%%% ejabberd, Copyright (C) 2002-2012   ProcessOne
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


-ifndef(mod_privacy_hrl).
-include("mod_privacy.hrl").
-endif.

-define(SETS, gb_sets).
-define(DICT, dict).

%% pres_a contains all the presence available send (either through roster mechanism or directed).
%% Directed presence unavailable remove user from pres_a.
-record(state, {socket,
		sockmod,
		socket_monitor,
		xml_socket,
		streamid,
		sasl_state,
		access,
		shaper,
		zlib = false,
		tls = false,
		tls_required = false,
		tls_enabled = false,
		tls_options = [],
		authenticated = false,
		jid,
		user = "", server = ?MYNAME, resource = "",
		sid,
		pres_t = ?SETS:new(),
		pres_f = ?SETS:new(),
		pres_a = ?SETS:new(),
		pres_i = ?SETS:new(),
		pres_last, pres_pri,
		pres_timestamp,
		pres_invis = false,
		privacy_list = #userlist{},
		conn = unknown,
		auth_module = unknown,
		ip,
                redirect = false,
                aux_fields = [],
		fsm_limit_opts,
		lang,
		debug=false,
		flash_connection = false,
		reception = true,
		standby = false,
		queue = queue:new(),
		queue_len = 0,
		pres_queue = gb_trees:empty(),
		keepalive_timer,
		keepalive_timeout,
		oor_timeout,
		oor_status = "",
		oor_show = "",
		oor_notification,
		oor_send_body = all,
		oor_send_groupchat = false,
		oor_send_from = jid,
		oor_appid = "",
		oor_unread = 0,
		oor_unread_users = ?SETS:new(),
		oor_unread_client = 0,
                oor_offline = false,
		ack_enabled = false,
		ack_counter = 0,
		ack_queue = queue:new(),
		ack_timer}).
