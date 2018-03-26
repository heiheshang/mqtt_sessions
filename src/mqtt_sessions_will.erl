%% @doc Watchdog process, publishes the will if a session process fails.

-module(mqtt_sessions_will).

-behaviour(gen_server).

-export([
    start_link/2,
    connected/4,
    reconnected/1,
    disconnected/3,
    disconnected/1,
    set_user_context/2,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-record(state, {
    pool :: atom(),
    session_pid :: pid(),
    will :: map(),
    user_context :: term(),
    session_expiry_interval :: non_neg_integer(),
    expiry_ref = undefined :: reference() | undefined,
    timer_ref = undefined,
    is_stopping :: boolean()
}).

%% The connect handshake must complete in 20 seconds.
-define(CONNECT_EXPIRY_INTERVAL, 20).


-spec start_link( atom(), pid() ) -> {ok, pid()}.
start_link(Pool, SessionPid) ->
    gen_server:start_link(?MODULE, [Pool, SessionPid], []).

%% @todo Race condition: the will process might have stopped (and sent the will)
%%       In the time the new connect is handled. If so the will process is now
%%       killing the session, which will force the client to re-connect.
-spec connected(pid(), map() | undefined, non_neg_integer(), term()) -> ok.
connected(Pid, Will, SessionExpiry, UserContext) ->
    gen_server:cast(Pid, {connected, Will, SessionExpiry, UserContext}).

-spec reconnected(pid()) -> ok.
reconnected(Pid) ->
    gen_server:cast(Pid, reconnected).

%% @doc Signal the will process that the session got disconnected from the client.
-spec disconnected(pid() | undefined, boolean(), pos_integer()) -> ok.
disconnected(Pid, IsWill, ExpiryInterval) ->
    gen_server:cast(Pid, {disconnected, IsWill, ExpiryInterval}).

-spec disconnected(pid()) -> ok.
disconnected(Pid) ->
    gen_server:cast(Pid, disconnected).


%% @doc Set a new user context, needed after reauthentication
-spec set_user_context(pid(), term()) -> ok.
set_user_context(Pid, UserContext) ->
    gen_server:cast(Pid, {user_context, UserContext}).

%% @doc Sync request to stop the will process
-spec stop( pid() | undefined ) -> ok.
stop(undefined) ->
    ok;
stop(Pid) ->
    gen_server:call(Pid, stop, infinity).


% ---------------------------------------------------------------------------------------
% --------------------------- gen_server functions --------------------------------------
% ---------------------------------------------------------------------------------------


init([ Pool, SessionPid ]) ->
    erlang:monitor(process, SessionPid),
    State = #state{
        pool = Pool,
        session_pid = SessionPid,
        will = #{},
        is_stopping = false
    },
    State1 = do_disconnected(State, ?CONNECT_EXPIRY_INTERVAL),
    {ok, State1}.

handle_call(stop, _From, State) ->
    self() ! stop,
    {reply, ok, stop_timer(State#state{ is_stopping = true })};
handle_call(Msg, _From, State) ->
    {stop, {unknown_message, Msg}, State}.

handle_cast({connected, undefined, SessionExpiry, UserContext}, State) ->
    State1 = State#state{
        user_context = UserContext,
        session_expiry_interval = SessionExpiry
    },
    {noreply, stop_timer(State1)};
handle_cast({connected, Will, SessionExpiry, UserContext}, State) ->
    State1 = State#state{
        will = Will,
        user_context = UserContext,
        session_expiry_interval = SessionExpiry
    },
    {noreply, stop_timer(State1)};
handle_cast(reconnected, State) ->
    {noreply, stop_timer(State)};

handle_cast({disconnected, IsWill, ExpiryInterval}, State) ->
    {noreply, do_disconnected(State, IsWill, ExpiryInterval)};
handle_cast(disconnected, State) ->
    {noreply, do_disconnected(State, true, undefined)};

handle_cast({user_context, UserContext}, State) ->
    {noreply, State#state{ user_context = UserContext }};

handle_cast(stop, State) ->
    {stop, shutdown, State};

handle_cast(Msg, State) ->
    {stop, {unknown_message, Msg}, State}.

handle_info({'DOWN', _Mref, process, Pid, _Reason}, #state{ session_pid = Pid } = State) ->
    % Session unexpectedly stopped, publish the will immediately
    do_publish_will(State),
    {stop, shutdown, State};
handle_info(stop, State) ->
    {stop, shutdown, State};
handle_info({expired, Ref}, #state{ expiry_ref = Ref } = State) ->
    mqtt_sessions_process:kill(State#state.session_pid),
    do_publish_will(State),
    {stop, shutdown, State};
handle_info({expired, Ref}, #state{ expiry_ref = Ref } = State) ->
    do_publish_will(State),
    {stop, shutdown, State};
handle_info({expired, _Ref}, State) ->
    % old timer - ignore
    {noreply, State}.

code_change(_Vsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

% ---------------------------------------------------------------------------------------
% ----------------------------- support functions ---------------------------------------
% ---------------------------------------------------------------------------------------

%% @doc Handle a disconnect of the MQTT connection, if not reconnected within the delay interval
%%      then we kill the connection process and the will is published.
do_disconnected(State, false, undefined) ->
    State1 = State#state{ will = #{} },
    do_disconnected(State1, maps:get(delay_interval, State#state.will, 0));
do_disconnected(State, false, DelayInterval) ->
    State1 = State#state{ will = #{} },
    do_disconnected(State1, DelayInterval);
do_disconnected(State, true, undefined) ->
    do_disconnected(State, maps:get(delay_interval, State#state.will, 0));
do_disconnected(State, true, DelayInterval) ->
    Delay = erlang:min(
        DelayInterval,
        maps:get(delay_interval, State#state.will, DelayInterval)),
    do_disconnected(State, Delay).

do_disconnected(State, DelayInterval) ->
    Ref = erlang:make_ref(),
    Timer = erlang:send_after(DelayInterval * 1000, self(), {expired, Ref}),
    State#state{ timer_ref = Timer, expiry_ref = Ref }.

stop_timer(#state{ timer_ref = undefined } = State) ->
    State;
stop_timer(#state{ timer_ref = TRef } = State) ->
    erlang:cancel_timer(TRef),
    State#state{ timer_ref = undefined, expiry_ref = undefined }.

%% @doc Publish the will message. A will is published if the connection process crashes or if
%%      it is has been disconnected for a too long time.
do_publish_will(#state{ is_stopping = true }) ->
    ok;
do_publish_will(#state{ pool = Pool, will = #{ topic := Topic, payload := Payload } = Will, user_context = UserContext }) ->
    Retain = maps:get(retain, Will, false),
    QoS = maps:get(qos, Will, 0),
    Props = maps:get(properties, Will, #{}),
    router:publish(Pool, Topic, Payload, #{ qos => QoS, retain => Retain, properties => Props }, UserContext);
do_publish_will(#state{}) ->
    ok.

