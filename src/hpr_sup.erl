%%%-------------------------------------------------------------------
%% @doc helium_packet_router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hpr_sup).

-behaviour(supervisor).

-include("hpr.hrl").

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(ELLI_WORKER(I, Args), #{
    id => I,
    start => {elli, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [elli]
}).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    KeyFileName = application:get_env(hpr, key, "/var/data/hpr.key"),

    lager:info("KeyFileName ~s", [KeyFileName]),

    ok = filelib:ensure_dir(KeyFileName),
    Key =
        case libp2p_crypto:load_keys(KeyFileName) of
            {ok, #{secret := PrivKey, public := PubKey}} ->
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)};
            {error, enoent} ->
                KeyMap =
                    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                        ecc_compact
                    ),
                ok = libp2p_crypto:save_keys(KeyMap, KeyFileName),
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)}
        end,
    ok = persistent_term:put(?HPR_KEY, Key),

    ok = hpr_routing:init(),
    ok = hpr_max_copies:init(),
    ok = hpr_protocol_router:init(),
    ok = hpr_route_ets:init(),
    ok = hpr_skf_ets:init(),

    HttpRoamingDownlink = application:get_env(?APP, http_roaming_downlink_port, 8090),
    PacketReporterConfig = application:get_env(?APP, packet_reporter, #{}),
    ConfigServiceConfig = application:get_env(?APP, config_service, #{}),

    %% Starting config service client channel here because of the way we get
    %% .env vars into the app.
    _ = maybe_start_config_channel(ConfigServiceConfig),

    ElliConfigMetrics = [
        {callback, hpr_metrics_handler},
        {port, 3000}
    ],
    ElliConfigRoamingDownlink = [
        {callback, hpr_http_roaming_downlink_handler},
        {port, HttpRoamingDownlink}
    ],

    ChildSpecs = [
        ?WORKER(hpr_metrics, [#{}]),
        ?ELLI_WORKER(hpr_metrics_handler, [ElliConfigMetrics]),

        ?WORKER(hpr_packet_reporter, [PacketReporterConfig]),

        ?WORKER(hpr_cs_route_stream_worker, [maps:get(route, ConfigServiceConfig, #{})]),
        ?WORKER(hpr_cs_skf_stream_worker, [#{}]),

        ?SUP(hpr_gwmp_sup, []),

        ?SUP(hpr_http_roaming_sup, []),
        ?ELLI_WORKER(hpr_http_roaming_downlink_handler, [ElliConfigRoamingDownlink])
    ],
    {ok, {
        #{
            strategy => one_for_one,
            intensity => 1,
            period => 5
        },
        ChildSpecs
    }}.

maybe_start_config_channel(Config) ->
    case Config of
        #{port := []} ->
            lager:error("no port provided for config channel");
        #{port := Port} when erlang:is_list(Port) ->
            maybe_start_config_channel(Config#{port => erlang:list_to_integer(Port)});
        #{host := Host, port := Port} ->
            _ = grpcbox_client:connect(config_channel, [{http, Host, Port, []}], #{});
        _ ->
            lager:error("no host and port to start config_channel")
    end.
