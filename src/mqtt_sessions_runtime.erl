%% @doc MQTT sessions runtime ACL interface.

-module(mqtt_sessions_runtime).

-export([
    new_user_context/2,
    connect/2,
    reauth/2,
    is_allowed/4
    ]).

-type user_context() :: term().
-type topic() :: list( binary() ).


-callback new_user_context( atom(), binary() ) -> term().
-callback connect( mqtt_packet_map:mqtt_packet(), user_context()) -> {ok, mqtt_packet_map:mqtt_packet(), user_context()} | {error, term()}.
-callback reauth( mqtt_packet_map:mqtt_packet(), user_context()) -> {ok, mqtt_packet_map:mqtt_packet(), user_context()} | {error, term()}.
-callback is_allowed( publish | subscribe, topic(), mqtt_packet_map:mqtt_packet(), user_context()) -> boolean().

-export_type([
    user_context/0,
    topic/0
]).

-define(none(A), (A =:= undefined orelse A =:= <<>>)).

-include_lib("mqtt_packet_map/include/mqtt_packet_map.hrl").

% TODO: check authentication credentials
% TODO: if reconnect, check against previous credentials (MUST be the same)

-spec new_user_context( atom(), binary() ) -> term().
new_user_context( Pool, ClientId ) ->
    #{
        pool => Pool,
        client_id => ClientId,
        user => undefined
    }.

-spec connect( mqtt_packet_map:mqtt_packet(), user_context()) -> {ok, mqtt_packet_map:mqtt_packet(), user_context()} | {error, term()}.
connect(#{ type := connect, username := U, password := P }, UserContext) when ?none(U), ?none(P) ->
    % Anonymous login
    ConnAck = #{
        type => connack,
        reason_code => ?MQTT_RC_SUCCESS
    },
    {ok, ConnAck, UserContext#{ user => undefined }};
connect(#{ type := connect, username := U, password := P }, UserContext) when not ?none(U), not ?none(P) ->
    % User logs on using username/password
    % ... check username/password
    % ... log on user on UserContext
    ConnAck = #{
        type => connack,
        reason_code => ?MQTT_RC_SUCCESS
    },
    {ok, ConnAck, UserContext#{ user => U }};
connect(#{ type := connect, properties := #{ authentication_method := AuthMethod } = Props }, UserContext) ->
    % User logs on using extended authentication method
    AuthData = maps:get(authentication_data, Props, undefined),
    % ... handle extended authentication handshake
    ConnAck = #{
        type => connack,
        reason_code => ?MQTT_RC_NOT_AUTHORIZED
    },
    {ok, ConnAck, UserContext};
connect(_Packet, UserContext) ->
    % Extended authentication
    ConnAck = #{
        type => connack,
        reason_code => ?MQTT_RC_NOT_AUTHORIZED
    },
    {ok, ConnAck, UserContext}.


%% @spec Re-authentication. This called when the client requests a re-authentication (or replies in a AUTH re-authentication).
-spec reauth( mqtt_packet_map:mqtt_packet(), user_context()) -> {ok, mqtt_packet_map:mqtt_packet(), user_context()} | {error, term()}.
reauth(#{ type := auth }, _UserContext) ->
    {error, notsupported}.


-spec is_allowed( publish | subscribe, topic(), mqtt_packet_map:mqtt_packet(), user_context()) -> boolean().
is_allowed(publish, _Topic, _Packet, _UserContext) ->
    true;
is_allowed(subscribe, _Topic, _Packet, _UserContext) ->
    true.
