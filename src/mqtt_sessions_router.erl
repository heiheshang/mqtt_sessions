%% @doc Process owning the MQTT topic router.

%% TODO: add topic bindings on retained publish

-module(mqtt_sessions_router).

-behaviour(gen_server).

-export([
    publish/3,
    publish/4,
    subscribe/4,
    subscribe/6,
    unsubscribe/3,
    start_link/1,
    name/1
    ]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
    ]).

-type mqtt_msg() :: #{
        pool => atom(),
        topic => list( binary() ),
        topic_bindings => list( proplists:property() ),
        message => mqtt_packet_map:mqtt_message(),
        publisher_context => term(),
        subscriber_context => term(),
        no_local => boolean(),
        qos => 0 | 1 | 2,
        retain_as_published => boolean(),
        retain_handling => integer()
    }.

-type subscriber_options() :: #{
        subscriber_context => term(),
        no_local => boolean(),
        qos => 0 | 1 | 2,
        retain_as_published => boolean(),
        retain_handling => integer()
    }.

-type subscriber() :: {pid() | mfa(), OwnerPid::pid(), subscriber_options()}.

-export_type([
    subscriber/0,
    mqtt_msg/0
]).

-record(state, {
        pool :: atom(),
        router :: router:router(),
        monitors :: map()
    }).

-include_lib("router/include/router.hrl").
-include_lib("../include/mqtt_sessions.hrl").


-spec publish( atom(), list(), mqtt_packet_map:mqtt_message() ) -> ok.
publish( Pool, Topic, Msg ) ->
    publish(Pool, Topic, Msg, undefined).

-spec publish( atom(), list(), mqtt_packet_map:mqtt_message(), term() ) -> ok.
publish( Pool, Topic, Msg, PublisherContext ) ->
    Paths = router:route(Pool, Topic),
    lists:map(
        fun(Route) ->
            publish_1(Pool, Topic, Route, Msg, PublisherContext)
        end,
        Paths),
    case maps:get(retain, Msg, false) of
        true -> mqtt_sessions_retain:retain(Pool, Msg, PublisherContext);
        false -> ok
    end,
    ok.

publish_1(Pool, Topic, #route{ bound_args = Bound, destination = Dest }, Msg, PublisherContext) ->
    case is_no_local(Dest, self()) of
        true ->
            ok;
        false ->
            {Callback, _OwnerPid, Options} = Dest,
            Msg1 = case maps:get(retain, Msg, false) of
                true ->
                    case maps:get(retain_as_published, Msg, false) of
                        false -> Msg#{ retain => false };
                        true -> Msg
                    end;
                false -> Msg
            end,
            MqttMsg = Options#{
                type => publish,
                pool => Pool,
                topic => Topic,
                topic_bindings => Bound,
                message => Msg1,
                publisher_context => PublisherContext
            },
            case Callback of
                {io, format, A} ->
                    erlang:apply(io, format, A ++ [ [ MqttMsg ] ]);
                {M,F,A} ->
                    erlang:apply(M, F, A ++ [ MqttMsg ]);
                Pid when is_pid(Pid) ->
                    Pid ! {mqtt_msg, MqttMsg}
            end
    end.

is_no_local({_Callback, OwnerPid, #{ no_local := true }}, OwnerPid) -> true;
is_no_local(_Destination, _Pid) -> false.


-spec subscribe( atom(), list(), subscriber(), term() ) -> ok | {error, invalid_subscriber}.
subscribe( Pool, Topic, {_, _, _} = MFA, SubscriberContext) ->
    subscribe( Pool, Topic, MFA, self(), #{}, SubscriberContext);
subscribe( Pool, Topic, Pid, SubscriberContext) when is_pid(Pid) ->
    subscribe( Pool, Topic, Pid, Pid, #{}, SubscriberContext).

subscribe( Pool, TopicFilter, Subscriber, OwnerPid, Options, SubscriberContext ) when is_pid(OwnerPid), is_map(Options) ->
    case is_valid_subscriber(Subscriber) of
        true ->
            case gen_server:call(name(Pool), {subscribe, TopicFilter, Subscriber, OwnerPid, Options}, infinity) of
                {ok, IsNew} ->
                    % Check retained messages, publish to the Subscriber
                    maybe_publish_retained(Pool, IsNew, TopicFilter, Subscriber, Options, SubscriberContext),
                    ok;
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, invalid_subscriber}
    end.

maybe_publish_retained(Pool, IsNew, TopicFilter, Subscriber, Options, SubscriberContext) ->
    case maps:get(retain_handling, Options, 0) of
        0 ->
            % All retained messages
            publish_retained(Pool, TopicFilter, Subscriber, Options, SubscriberContext);
        1 when IsNew ->
            % Only if new subscription
            publish_retained(Pool, TopicFilter, Subscriber, Options, SubscriberContext);
        _ ->
            ok
    end.

publish_retained(Pool, TopicFilter, Subscriber, Options, SubscriberContext) ->
    {ok, Ms} = mqtt_sessions_retain:lookup(Pool, TopicFilter),
    Runtime = mqtt_sessions:runtime(),
    lists:foreach(
        fun({#{ topic := Topic } = Msg, PublisherContext}) ->
            case Runtime:is_allowed(subscribe, Topic, Msg, SubscriberContext) of
                true ->
                    Bound = bind(Topic, TopicFilter),
                    Dest = {Subscriber, undefined, Options},
                    publish_1(Pool, Topic, #route{ bound_args = Bound, destination = Dest }, Msg, PublisherContext);
                false ->
                    ok
            end
        end,
        Ms).

-spec unsubscribe( atom(), list(), pid() ) -> ok | {error, notfound}.
unsubscribe( Pool, TopicFilter, Pid ) ->
    gen_server:call(name(Pool), {unsubscribe, TopicFilter, Pid}, infinity).


-spec start_link( atom() ) -> {ok, pid()} | {error, term()}.
start_link( Pool ) ->
    gen_server:start_link({local, name(Pool)}, ?MODULE, [Pool], []).


is_valid_subscriber({M, F, A}) when is_atom(M), is_atom(F), is_list(A) -> true;
is_valid_subscriber(Pid) when is_pid(Pid) -> true;
is_valid_subscriber(_) -> false.


% ---------------------------------------------------------------------------------------
% --------------------------- gen_server functions --------------------------------------
% ---------------------------------------------------------------------------------------

-spec init( [ atom() ]) -> {ok, #state{}}.
init([ Pool ]) ->
    {ok, #state{
        pool = Pool,
        router = router:new(Pool),
        monitors = #{}
    }}.

handle_call({subscribe, TopicFilter0, Subscriber, OwnerPid, Options}, _From,
            #state{ router = Router, monitors = Monitors } = State) ->
    TopicFilter = map_wildcards(TopicFilter0),
    Current = maps:get(OwnerPid, Monitors, []),
    {Current1, IsNew} = case lists:keysearch(TopicFilter, 1, Current) of
        {value, {_Filter, PrevSubscriber}} ->
            router:remove_path(Router, TopicFilter, PrevSubscriber),
            {lists:keydelete(TopicFilter, 1, Current), false};
        false ->
            {Current, true}
    end,
    Destination = {Subscriber, OwnerPid, Options},
    ok = router:add(Router, TopicFilter, Destination),
    case maps:is_key(OwnerPid, Monitors) of
        false -> erlang:monitor(process, OwnerPid);
        true -> ok
    end,
    Monitors1 = Monitors#{
        OwnerPid => [ {TopicFilter, Destination} | Current1
    ]},
    {reply, {ok, IsNew}, State#state{ monitors = Monitors1 }};
handle_call({unsubscribe, TopicFilter0, Pid}, _From,
            #state{ router = Router, monitors = Monitors } = State) ->
    TopicFilter = map_wildcards(TopicFilter0),
    Subs = maps:get(Pid, Monitors, []),
    case lists:keysearch(TopicFilter, 1, Subs) of
        {value, {_Filter, Destination}} ->
            router:remove_path(Router, TopicFilter, Destination),
            Subs1 = lists:keydelete(TopicFilter, 1, Subs),
            Monitors1 = Monitors#{ Pid => Subs1 },
            {reply, ok, State#state{ monitors = Monitors1 }};
        false ->
            {reply, {error, notfound}, State}
    end;
handle_call(Cmd, _From, State) ->
    {stop, {unknown_cmd, Cmd}, State}.

handle_cast(Cmd, State) ->
    {stop, {unknown_cmd, Cmd}, State}.

handle_info({'DOWN', _Mref, Pid, process, _Reason}, State) ->
    {noreply, remove_subscriber(Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_Vsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

% ---------------------------------------------------------------------------------------
% ----------------------------- support functions ---------------------------------------
% ---------------------------------------------------------------------------------------

%% Bind variables from the match to the path
%%
bind(Path, Match) ->
    bind(Path, Match, []).

bind([], [], Acc) ->
    lists:reverse(Acc);
bind(P, [<<"#">>], Acc) ->
    lists:reverse([{'#', P}|Acc]);
bind([H|Path], [<<"+">>|Match], Acc) ->
    bind(Path, Match, [H|Acc]);
bind([_|Path], [_|Match], Acc) ->
    bind(Path, Match, Acc).


map_wildcards(TopicFilter) ->
    lists:map(
        fun
            (<<"#">>) -> '#';
            (<<"+">>) -> '+';
            (T) -> T
        end,
        TopicFilter).


%% @doc Remove all subscriptions belonging to a certain process
remove_subscriber(Pid, #state{ router = Router, monitors = Monitors } = State) ->
    lists:foreach(
        fun({TopicFilter, Subscriber}) ->
            router:remove_path(Router, TopicFilter, Subscriber)
        end,
        maps:get(Pid, Monitors, [])),
    State#state{ monitors = maps:remove(Pid, Monitors) }.


-spec name( atom() ) -> atom().
name( Pool ) ->
    list_to_atom(atom_to_list(Pool) ++ "$router").