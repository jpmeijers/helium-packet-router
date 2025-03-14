%%%-------------------------------------------------------------------
%% @doc pp_cli_config
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cli_config).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [config_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [config_cmd()]
    ).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

config_usage() ->
    [
        ["config"],
        [
            "\n\n",
            "config ls                                   - List\n",
            "config oui <oui>                            - Info for OUI\n",
            "    [--display_euis] default: false (EUIs not included)\n",
            "    [--display_skfs] default: false (SKFs not included)\n",
            "config route <route_id>                     - Info for route\n",
            "    [--display_euis] default: false (EUIs not included)\n",
            "    [--display_skfs] default: false (SKFs not included)\n",
            "config route refresh <route_id>             - Refresh route\n",
            "config route activate <route_id>            - Activate route\n",
            "config route deactivate <route_id>          - Deactivate route\n",
            "config skf <DevAddr/Session Key>            - List all Session Key Filters for Devaddr or Session Key\n",
            "config eui --app <app_eui> --dev <dev_eui>  - List all Routes with EUI pair\n"
        ]
    ].

config_cmd() ->
    [
        [["config", "ls"], [], [], fun config_list/3],
        [
            ["config", "oui", '*'],
            [],
            [
                {display_euis, [{longname, "display_euis"}, {datatype, boolean}]},
                {display_skfs, [{longname, "display_skfs"}, {datatype, boolean}]}
            ],
            fun config_oui_list/3
        ],
        [
            ["config", "route", '*'],
            [],
            [
                {display_euis, [{longname, "display_euis"}, {datatype, boolean}]},
                {display_skfs, [{longname, "display_skfs"}, {datatype, boolean}]}
            ],
            fun config_route/3
        ],
        [
            ["config", "route", "refresh", '*'],
            [],
            [],
            fun config_route_refresh/3
        ],
        [
            ["config", "route", "activate", '*'],
            [],
            [],
            fun config_route_activate/3
        ],
        [
            ["config", "route", "deactivate", '*'],
            [],
            [],
            fun config_route_deactivate/3
        ],
        [["config", "skf", '*'], [], [], fun config_skf/3],
        [
            ["config", "eui"],
            [],
            [
                {app_eui, [
                    {shortname, "a"},
                    {longname, "app"}
                ]},
                {dev_eui, [
                    {shortname, "d"},
                    {longname, "dev"}
                ]}
            ],
            fun config_eui/3
        ]
    ].

config_list(["config", "ls"], [], []) ->
    Routes = lists:sort(
        fun(R1, R2) -> hpr_route:oui(R1) < hpr_route:oui(R2) end,
        hpr_route_ets:all_routes()
    ),
    %% | OUI | Net ID | Protocol     | Max Copies | Addr Range Cnt | EUI Cnt | Route ID                             |
    %% |-----+--------+--------------+------------+----------------+---------+--------------------------------------|
    %% |   1 | 000001 | gwmp         |         15 |              4 |       4 | b1eed652-b85c-11ed-8c9d-bfa0a604afc0 |
    %% |   4 | 000002 | http_roaming |        999 |              3 |       4 | 91236f72-a98a-11ed-aacb-830d346922b8 |
    MkRow = fun(Route) ->
        Server = hpr_route:server(Route),
        [
            {" OUI ", hpr_route:oui(Route)},
            {" Net ID ", hpr_utils:net_id_display(hpr_route:net_id(Route))},
            {" Protocol ", hpr_route:protocol_type(Server)},
            {" Max Copies ", hpr_route:max_copies(Route)},
            {" Addr Ranges Cnt ",
                hpr_route_ets:devaddr_ranges_count_for_route(hpr_route:id(Route))},
            {" EUIs Cnt ", hpr_route_ets:eui_pairs_count_for_route(hpr_route:id(Route))},
            {" SKFs Cnt ", hpr_route_ets:skfs_count_for_route(hpr_route:id(Route))},
            {" Route ID ", hpr_route:id(Route)}
        ]
    end,
    c_table(lists:map(MkRow, Routes));
config_list(_, _, _) ->
    usage.

config_oui_list(["config", "oui", OUIString], [], Flags) ->
    Options = maps:from_list(Flags),
    OUI = erlang:list_to_integer(OUIString),
    RoutesETS = hpr_route_ets:oui_routes(OUI),

    %% OUI 4
    %% ========================================================
    %% - ID         :: 48088786-5465-4115-92de-5214a88e9a75
    %% - Nonce      :: 1
    %% - Net ID     :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server     :: Host:Port
    %% - Protocol   :: {gwmp, ...}
    %% - Backoff    :: 0
    %% - Active     :: true
    %% - Locked     :: false
    %% - Ignore Empty SKF :: true
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Count (AppEUI, DevEUI) :: 2
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)
    %% - SKF (DevAddr, SKF, MaxCopies) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Header = io_lib:format("OUI ~p~n", [OUI]),
    Spacer = io_lib:format("========================================================~n", []),

    DisplayOptions = #{
        display_euis => maps:is_key(display_euis, Options),
        display_skfs => maps:is_key(display_skfs, Options)
    },

    c_list(
        lists:foldl(
            fun(RouteETS, Lines) ->
                Lines ++ [Spacer | mk_route_info(RouteETS, DisplayOptions)]
            end,
            [Header],
            RoutesETS
        )
    );
config_oui_list(_, _, _) ->
    usage.

config_route(["config", "route", RouteID], [], Flags) ->
    Options = maps:from_list(Flags),
    RoutesETS = hpr_route_ets:lookup_route(RouteID),

    %% ========================================================
    %% - ID         :: 48088786-5465-4115-92de-5214a88e9a75
    %% - Nonce      :: 1
    %% - Net ID     :: C00053 (124781673)
    %% - Max Copies :: 1337
    %% - Server     :: Host:Port
    %% - Protocol   :: {gwmp, ...}
    %% - Backoff    :: 0
    %% - Active     :: true
    %% - Locked     :: false
    %% - Ignore Empty SKF :: true
    %% - DevAddr Ranges
    %% --- Start -> End
    %% --- Start -> End
    %% - EUI Count (AppEUI, DevEUI) :: 2
    %% --- (010203040506070809, 010203040506070809)
    %% --- (0A0B0C0D0E0F0G0102, 0A0B0C0D0E0F0G0102)
    %% - SKF (DevAddr, SKF, MaxCopies, Timestamp) :: 1
    %% --- (00000007, 91919193DA7B33923FFBE34078000010, 2, 1689030396950)

    Spacer = io_lib:format("========================================================~n", []),

    DisplayOptions = #{
        display_euis => maps:is_key(display_euis, Options),
        display_skfs => maps:is_key(display_skfs, Options)
    },

    c_list(
        lists:foldl(
            fun(RouteETS, Lines) ->
                Lines ++ [Spacer | mk_route_info(RouteETS, DisplayOptions)]
            end,
            [],
            RoutesETS
        )
    );
config_route(_, _, _) ->
    usage.

config_route_refresh(["config", "route", "refresh", RouteID], [], _Flags) ->
    case hpr_route_stream_worker:refresh_route(RouteID) of
        {ok, RefreshMap} ->
            Table = [
                [
                    {" Type ", eui},
                    {" Before ", maps:get(eui_before, RefreshMap)},
                    {" After ", maps:get(eui_after, RefreshMap)},
                    {" Removed ", maps:get(eui_removed, RefreshMap)},
                    {" Added ", maps:get(eui_added, RefreshMap)}
                ],
                [
                    {" Type ", skf},
                    {" Before ", maps:get(skf_before, RefreshMap)},
                    {" After ", maps:get(skf_after, RefreshMap)},
                    {" Removed ", maps:get(skf_removed, RefreshMap)},
                    {" Added ", maps:get(skf_added, RefreshMap)}
                ],
                [
                    {" Type ", devaddr_range},
                    {" Before ", maps:get(devaddr_before, RefreshMap)},
                    {" After ", maps:get(devaddr_after, RefreshMap)},
                    {" Removed ", maps:get(devaddr_removed, RefreshMap)},
                    {" Added ", maps:get(devaddr_added, RefreshMap)}
                ]
            ],
            c_table(Table);
        Err ->
            c_text("Something went wrong:~n~p", [Err])
    end;
config_route_refresh(_, _, _) ->
    usage.

config_route_activate(["config", "route", "activate", RouteID], [], _Flags) ->
    case hpr_route_ets:lookup_route(RouteID) of
        [] ->
            c_text("Route ~s not found", [RouteID]);
        [RouteETS] ->
            Route0 = hpr_route_ets:route(RouteETS),
            Route1 = hpr_route:active(true, Route0),
            ok = hpr_route_ets:insert_route(Route1),
            c_text("Route ~s activated", [RouteID])
    end;
config_route_activate(_, _, _) ->
    usage.

config_route_deactivate(["config", "route", "deactivate", RouteID], [], _Flags) ->
    case hpr_route_ets:lookup_route(RouteID) of
        [] ->
            c_text("Route ~s not found", [RouteID]);
        [RouteETS] ->
            Route0 = hpr_route_ets:route(RouteETS),
            Route1 = hpr_route:active(false, Route0),
            ok = hpr_route_ets:insert_route(Route1),
            c_text("Route ~s deactivated", [RouteID])
    end;
config_route_deactivate(_, _, _) ->
    usage.

config_skf(["config", "skf", DevAddrOrSKF], [], []) ->
    SKFS =
        case hpr_utils:hex_to_bin(erlang:list_to_binary(DevAddrOrSKF)) of
            <<DevAddr:32/integer-unsigned-little>> ->
                lists:foldl(
                    fun(RouteETS, Acc) ->
                        Route = hpr_route_ets:route(RouteETS),
                        RouteID = hpr_route:id(Route),
                        ETS = hpr_route_ets:skf_ets(RouteETS),
                        [
                            {DevAddr, SK, RouteID, MaxCopies}
                         || {SK, MaxCopies} <- hpr_route_ets:lookup_skf(ETS, DevAddr)
                        ] ++ Acc
                    end,
                    [],
                    hpr_route_ets:lookup_devaddr_range(DevAddr)
                );
            SKF ->
                RoutesETS = hpr_route_ets:all_route_ets(),
                find_skf(SKF, RoutesETS, [])
        end,
    case SKFS of
        [] ->
            c_text("No SKF found for ~p", [DevAddrOrSKF]);
        SKFs ->
            MkRow = fun({DevAddr, SK, RouteID, MaxCopies}) ->
                [
                    {" Route ID ", RouteID},
                    {" Session Key ", hpr_utils:bin_to_hex_string(SK)},
                    {" Max Copies ", MaxCopies},
                    {" DevAddr ", hpr_utils:int_to_hex_string(DevAddr)}
                ]
            end,
            c_table(lists:map(MkRow, SKFs))
    end;
config_skf(_, _, _) ->
    usage.

find_skf(_SKToFind, [], Acc) ->
    Acc;
find_skf(SKToFind, [RouteETS | RoutesETS], Acc0) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),
    case hpr_route_ets:skfs_for_route(RouteID) of
        [] ->
            find_skf(SKToFind, RoutesETS, Acc0);
        SKFs ->
            Acc1 = lists:filtermap(
                fun({SK, {DevAddr, MaxCopies}}) ->
                    case SK =:= SKToFind of
                        true ->
                            {true, {DevAddr, SK, RouteID, MaxCopies}};
                        false ->
                            false
                    end
                end,
                SKFs
            ),
            find_skf(SKToFind, RoutesETS, Acc0 ++ Acc1)
    end.

config_eui(["config", "eui"], [], Flags) ->
    case maps:from_list(Flags) of
        #{app_eui := AppEUI, dev_eui := DevEUI} -> do_config_eui(AppEUI, DevEUI);
        #{app_eui := AppEUI} -> do_single_eui(app_eui, AppEUI);
        #{dev_eui := DevEUI} -> do_single_eui(dev_eui, DevEUI);
        _ -> usage
    end;
config_eui(_, _, _) ->
    usage.

do_config_eui(AppEUI, DevEUI) ->
    AppEUINum = erlang:list_to_integer(AppEUI, 16),
    DevEUINum = erlang:list_to_integer(DevEUI, 16),

    Found = hpr_route_ets:lookup_eui_pair(AppEUINum, DevEUINum),

    %% ======================================================
    %% - App EUI :: 6081F9413229AD32 (6954113358046539058)
    %% - Dev EUI :: D52B4AD7C7D613C5 (15360453244708328389)
    %% - Routes  :: 1 (OUI, Route ID)
    %%   -- (60, "7c3071f8-b4ae-11ed-becd-7f254cab7af3")
    %%

    Spacer = [io_lib:format("========================================================~n", [])],
    Info = [
        io_lib:format("- App EUI :: ~p (~p)~n", [AppEUI, AppEUINum]),
        io_lib:format("- Dev EUI :: ~p (~p)~n", [DevEUI, DevEUINum]),
        io_lib:format("- Routes  :: ~p (OUI, Route ID)~n", [erlang:length(Found)])
    ],

    Routes = lists:map(
        fun(RouteETS) ->
            Route = hpr_route_ets:route(RouteETS),
            io_lib:format("  -- (~p, ~p)~n", [hpr_route:oui(Route), hpr_route:id(Route)])
        end,
        Found
    ),

    c_list(Spacer ++ Info ++ Routes).

do_single_eui(app_eui, AppEUI) ->
    EUINum = erlang:list_to_integer(AppEUI, 16),
    Found = hpr_route_ets:lookup_app_eui(EUINum),

    %% ======================================================
    %% - App EUI :: 6081F9413229AD32 (6954113358046539058)
    %% - Count  :: 1 (AppEUI, DevEUI)
    %%   -- (6081F9413229AD32, 0102030405060708)
    %%

    Spacer = [io_lib:format("========================================================~n", [])],
    Info = [
        io_lib:format("- App EUI :: ~p (~p)~n", [AppEUI, EUINum]),
        io_lib:format("- Count   :: ~p (AppEUI, DevEUI)~n", [erlang:length(Found)])
    ],

    EUIsInfo = lists:map(fun format_eui/1, Found),
    c_list(Spacer ++ Info ++ EUIsInfo);
do_single_eui(dev_eui, DevEUI) ->
    EUINum = erlang:list_to_integer(DevEUI, 16),
    Found = hpr_route_ets:lookup_dev_eui(EUINum),

    %% ======================================================
    %% - Dev EUI :: 6081F9413229AD32 (6954113358046539058)
    %% - Count  :: 1 (AppEUI, DevEUI)
    %%   -- (0102030405060708, 6081F9413229AD32)
    %%

    Spacer = [io_lib:format("========================================================~n", [])],
    Info = [
        io_lib:format("- Dev EUI :: ~p (~p)~n", [DevEUI, EUINum]),
        io_lib:format("- Count   :: ~p (AppEUI, DevEUI)~n", [erlang:length(Found)])
    ],

    EUIsInfo = lists:map(fun format_eui/1, Found),
    c_list(Spacer ++ Info ++ EUIsInfo).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).

-spec mk_route_info(hpr_route_ets:route(), DisplayOptions :: map()) -> list(string()).
mk_route_info(RouteETS, #{display_euis := DisplayEUIs, display_skfs := DisplaySKFs}) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),

    DevAddrHeader = io_lib:format("- DevAddr Ranges~n", []),
    DevAddrRanges = lists:map(
        fun format_devaddr/1, hpr_route_ets:devaddr_ranges_for_route(RouteID)
    ),
    DevAddrInfo = [DevAddrHeader | DevAddrRanges],

    EUIInfo =
        case DisplayEUIs of
            false ->
                Count = hpr_route_ets:eui_pairs_count_for_route(RouteID),
                EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [Count]),
                [EUIHeader];
            true ->
                EUIs = hpr_route_ets:eui_pairs_for_route(RouteID),
                EUIHeader = io_lib:format("- EUI (AppEUI, DevEUI) :: ~p~n", [
                    erlang:length(EUIs)
                ]),
                [EUIHeader | lists:map(fun format_eui/1, EUIs)]
        end,

    SKFInfo =
        case DisplaySKFs of
            false ->
                SKFsCount = hpr_route_ets:skfs_count_for_route(RouteID),
                SKFHeader = io_lib:format(
                    "- SKF (DevAddr, SKF, MaxCopies) :: ~p~n", [SKFsCount]
                ),
                [SKFHeader];
            true ->
                SKFs = hpr_route_ets:skfs_for_route(RouteID),
                SKFHeader = io_lib:format(
                    "- SKF (DevAddr, SKF, MaxCopies) :: ~p~n", [
                        erlang:length(SKFs)
                    ]
                ),
                [SKFHeader | lists:map(fun format_skf/1, SKFs)]
        end,

    mk_top_level_route_info(RouteETS) ++ DevAddrInfo ++ EUIInfo ++ SKFInfo.

-spec mk_top_level_route_info(hpr_route_ets:route()) -> list(string()).
mk_top_level_route_info(RouteETS) ->
    Route = hpr_route_ets:route(RouteETS),
    RouteID = hpr_route:id(Route),
    NetID = hpr_route:net_id(Route),
    Server = hpr_route:server(Route),
    Backoff =
        case hpr_route_ets:backoff(RouteETS) of
            undefined -> 0;
            {Timestamp, _} -> Timestamp
        end,
    [
        io_lib:format("- ID         :: ~s~n", [RouteID]),
        io_lib:format("- Net ID     :: ~s (~p)~n", [hpr_utils:net_id_display(NetID), NetID]),
        io_lib:format("- Max Copies :: ~p~n", [hpr_route:max_copies(Route)]),
        io_lib:format("- Server     :: ~s~n", [hpr_route:lns(Route)]),
        io_lib:format("- Protocol   :: ~p~n", [hpr_route:protocol(Server)]),
        io_lib:format("- Backoff    :: ~w~n", [Backoff]),
        io_lib:format("- Active     :: ~w~n", [hpr_route:active(Route)]),
        io_lib:format("- Locked     :: ~w~n", [hpr_route:locked(Route)]),
        io_lib:format("- Ignore Empty SKF :: ~w~n", [hpr_route:ignore_empty_skf(Route)])
    ].

format_devaddr({S, E}) ->
    io_lib:format("  - ~s -> ~s~n", [
        hpr_utils:int_to_hex_string(S), hpr_utils:int_to_hex_string(E)
    ]).

format_eui({App, Dev}) ->
    io_lib:format("  - (~s, ~s)~n", [
        hpr_utils:int_to_hex_string(App), hpr_utils:int_to_hex_string(Dev)
    ]).

format_skf({SKF, {DevAddr, MaxCopies}}) ->
    io_lib:format("  - (~s, ~s, ~w)~n", [
        hpr_utils:int_to_hex_string(DevAddr),
        hpr_utils:bin_to_hex_string(SKF),
        MaxCopies
    ]).
