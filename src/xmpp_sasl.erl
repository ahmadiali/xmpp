%%%----------------------------------------------------------------------
%%% File    : xmpp_sasl.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Cyrus SASL-like library
%%% Created :  8 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2018   ProcessOne
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

-module(xmpp_sasl).

-author('alexey@process-one.net').

-export([server_new/7, server_start/3, server_step/2,
	 listmech/0, format_error/2]).

-record(sasl_state, {service,
		     myname,
		     realm,
		     get_password,
		     check_password,
		     check_password_digest,
		     mech_name = <<"">>,
		     mech_mod,
		     mech_state}).

-type mechanism() :: binary().
-type sasl_state() :: #sasl_state{}.
-type sasl_property() :: {username, binary()} |
			 {authzid, binary()} |
			 {mechanism, binary()} |
			 {auth_module, atom()}.
-type sasl_return() :: {ok, [sasl_property()]} |
		       {ok, [sasl_property()], binary()} |
		       {continue, binary(), sasl_state()} |
		       {error, atom(), binary()}.
-type error_reason() :: xmpp_sasl_digest:error_reason() |
			xmpp_sasl_oauth:error_reason() |
			xmpp_sasl_plain:error_reason() |
			xmpp_sasl_scram:error_reason() |
			unsupported_mechanism | nodeprep_failed |
			empty_username | aborted.

-export_type([mechanism/0, error_reason/0,
	      sasl_state/0, sasl_return/0, sasl_property/0]).

-callback mech_new(binary(), fun(), fun(), fun()) -> any().
-callback mech_step(any(), binary()) -> sasl_return().

%%%===================================================================
%%% API
%%%===================================================================
-spec format_error(mechanism() | sasl_state(), error_reason()) -> {atom(), binary()}.
format_error(_, unsupported_mechanism) ->
    {'invalid-mechanism', <<"Unsupported mechanism">>};
format_error(_, nodeprep_failed) ->
    {'bad-protocol', <<"Nodeprep failed">>};
format_error(_, empty_username) ->
    {'bad-protocol', <<"Empty username">>};
format_error(_, aborted) ->
    {'aborted', <<"Aborted">>};
format_error(#sasl_state{mech_mod = Mod}, Reason) ->
    Mod:format_error(Reason);
format_error(Mech, Reason) ->
    case get_mod(Mech) of
	undefined ->
	    {'invalid-mechanism', <<"Unsupported mechanism">>};
	Mod ->
	    Mod:format_error(Reason)
    end.

-spec listmech() -> [mechanism()].
listmech() ->
    [<<"ANONYMOUS">>,<<"DIGEST-MD5">>,<<"PLAIN">>,
     <<"SCRAM-SHA-1">>,<<"X-OAUTH2">>].

-spec server_new(binary(), binary(), binary(), term(),
		 fun(), fun(), fun()) -> sasl_state().
server_new(Service, ServerFQDN, UserRealm, _SecFlags,
	   GetPassword, CheckPassword, CheckPasswordDigest) ->
    #sasl_state{service = Service, myname = ServerFQDN,
		realm = UserRealm, get_password = GetPassword,
		check_password = CheckPassword,
		check_password_digest = CheckPasswordDigest}.

-spec server_start(sasl_state(), mechanism(), binary()) -> sasl_return().
server_start(State, Mech, ClientIn) ->
    case get_mod(Mech) of
	undefined ->
	    {error, unsupported_mechanism, <<"">>};
	Module ->
	    MechState = Module:mech_new(State#sasl_state.myname,
					State#sasl_state.get_password,
					State#sasl_state.check_password,
					State#sasl_state.check_password_digest),
	    State1 = State#sasl_state{mech_mod = Module,
				      mech_name = Mech,
				      mech_state = MechState},
	    server_step(State1, ClientIn)
    end.

-spec server_step(sasl_state(), binary()) -> sasl_return().
server_step(State, ClientIn) ->
    Module = State#sasl_state.mech_mod,
    MechState = State#sasl_state.mech_state,
    case Module:mech_step(MechState, ClientIn) of
        {ok, Props} ->
            case check_credentials(Props) of
                ok             -> {ok, Props};
                {error, Error} -> {error, Error, <<"">>}
            end;
        {ok, Props, ServerOut} ->
            case check_credentials(Props) of
                ok             -> {ok, Props, ServerOut};
                {error, Error} -> {error, Error, <<"">>}
            end;
        {continue, ServerOut, NewMechState} ->
            {continue, ServerOut, State#sasl_state{mech_state = NewMechState}};
        {error, Error, Username} ->
            {error, Error, Username};
        {error, Error} ->
            {error, Error, <<"">>}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec check_credentials([sasl_property()]) -> ok | {error, error_reason()}.
check_credentials(Props) ->
    User = proplists:get_value(authzid, Props, <<>>),
    case jid:nodeprep(User) of
	error -> {error, nodeprep_failed};
	<<"">> -> {error, empty_username};
	_LUser -> ok
    end.

-spec get_mod(binary()) -> module() | undefined.
get_mod(<<"ANONYMOUS">>) -> xmpp_sasl_anonymous;
get_mod(<<"DIGEST-MD5">>) -> xmpp_sasl_digest;    
get_mod(<<"X-OAUTH2">>) -> xmpp_sasl_oauth;
get_mod(<<"PLAIN">>) -> xmpp_sasl_plain;
get_mod(<<"SCRAM-SHA-1">>) -> xmpp_sasl_scram;
get_mod(_) -> undefined.