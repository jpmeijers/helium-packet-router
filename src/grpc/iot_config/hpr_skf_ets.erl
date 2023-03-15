-module(hpr_skf_ets).

-include("../autogen/iot_config_pb.hrl").

-export([
    init/0,
    insert/1,
    delete/1,
    lookup_devaddr/1,
    delete_all/0
]).

-define(ETS, hpr_skf_ets).

-spec init() -> ok.
init() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        bag,
        {read_concurrency, true}
    ]),
    ok.

-spec insert(SKF :: hpr_skf:skf()) -> ok.
insert(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    true = ets:insert(?ETS, {DevAddr, hpr_utils:hex_to_bin(SessionKey)}),
    lager:debug(
        [
            {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
            {session_key, SessionKey}
        ],
        "inserting SKF"
    ),
    ok.

-spec delete(SKF :: hpr_skf:skf()) -> ok.
delete(SKF) ->
    DevAddr = hpr_skf:devaddr(SKF),
    SessionKey = hpr_skf:session_key(SKF),
    true = ets:delete_object(?ETS, {DevAddr, hpr_utils:hex_to_bin(SessionKey)}),
    lager:debug(
        [
            {devaddr, hpr_utils:int_to_hex_string(DevAddr)},
            {session_key, SessionKey}
        ],
        "deleting SKF"
    ),
    ok.

-spec lookup_devaddr(DevAddr :: non_neg_integer()) ->
    {error, not_found} | {ok, [binary()]}.
lookup_devaddr(DevAddr) ->
    case ets:lookup(?ETS, DevAddr) of
        [] -> {error, not_found};
        SKFs -> {ok, [SessionKey || {_DevAddr, SessionKey} <- SKFs]}
    end.

-spec delete_all() -> ok.
delete_all() ->
    ets:delete_all_objects(?ETS),
    ok.

%% ------------------------------------------------------------------
%% EUnit tests
%% ------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test_() ->
    {setup, fun setup/0,
        {foreach, fun foreach_setup/0, fun foreach_cleanup/1, [
            ?_test(test_insert()),
            ?_test(test_delete()),
            ?_test(test_lookup_devaddr()),
            ?_test(test_delete_all())
        ]}}.

setup() ->
    ok.

foreach_setup() ->
    ?MODULE:init(),
    ok.

foreach_cleanup(ok) ->
    true = ets:delete(?ETS),
    ok.

test_insert() ->
    SKF = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF)),
    DevAddr = hpr_skf:devaddr(SKF),
    ?assertEqual(
        [{DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF))}], ets:lookup(?ETS, DevAddr)
    ),
    ok.

test_delete() ->
    SKF1 = new_skf(),
    SKF2 = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF1)),
    ?assertEqual(ok, ?MODULE:insert(SKF2)),
    DevAddr = hpr_skf:devaddr(SKF1),
    ?assertEqual(
        [
            {DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF1))},
            {DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF2))}
        ],
        ets:lookup(?ETS, DevAddr)
    ),
    ?assertEqual(ok, ?MODULE:delete(SKF1)),
    ?assertEqual(
        [{DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF2))}], ets:lookup(?ETS, DevAddr)
    ),
    ?assertEqual(ok, ?MODULE:delete(SKF2)),
    ?assertEqual([], ets:lookup(?ETS, DevAddr)),
    ok.

test_lookup_devaddr() ->
    SKF1 = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF1)),
    DevAddr = hpr_skf:devaddr(SKF1),
    ?assertEqual(
        {ok, [hpr_utils:hex_to_bin(hpr_skf:session_key(SKF1))]}, ?MODULE:lookup_devaddr(DevAddr)
    ),
    SKF2 = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF2)),
    ?assertEqual(
        {ok, [
            hpr_utils:hex_to_bin(hpr_skf:session_key(SKF1)),
            hpr_utils:hex_to_bin(hpr_skf:session_key(SKF2))
        ]},
        ?MODULE:lookup_devaddr(DevAddr)
    ),
    ok.

new_skf() ->
    DevAddr = 16#00000000,
    SessionKeys = hpr_utils:bin_to_hex_string(crypto:strong_rand_bytes(16)),
    SKFMap = #{
        oui => 1,
        devaddr => DevAddr,
        session_key => SessionKeys
    },
    hpr_skf:test_new(SKFMap).

test_delete_all() ->
    SKF1 = new_skf(),
    SKF2 = new_skf(),
    ?assertEqual(ok, ?MODULE:insert(SKF1)),
    ?assertEqual(ok, ?MODULE:insert(SKF2)),
    DevAddr = hpr_skf:devaddr(SKF1),
    ?assertEqual(
        [
            {DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF1))},
            {DevAddr, hpr_utils:hex_to_bin(hpr_skf:session_key(SKF2))}
        ],
        ets:lookup(?ETS, DevAddr)
    ),
    ?assertEqual(ok, ?MODULE:delete_all()),
    ?assertEqual([], ets:tab2list(?ETS)),
    ok.

-endif.
