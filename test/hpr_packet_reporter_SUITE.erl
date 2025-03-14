%%--------------------------------------------------------------------
%% @doc
%% To run this SUITE:
%% - `docker-compose -f docker-compose-ct.yaml up`
%% - Set HPR_PACKET_REPORTER_LOCAL_HOST=localhost
%% - Set HPR_PACKET_REPORTER_LOCAL_PORT=4556
%% HPR_PACKET_REPORTER_LOCAL_HOST=localhost HPR_PACKET_REPORTER_LOCAL_PORT=4566 ./rebar3 ct --suite=hpr_packet_reporter_SUITE
%% @end
%%--------------------------------------------------------------------
-module(hpr_packet_reporter_SUITE).

-include_lib("eunit/include/eunit.hrl").

-include("hpr.hrl").
-include("hpr_metrics.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    upload_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        upload_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    case
        {
            os:getenv("HPR_PACKET_REPORTER_LOCAL_HOST", []),
            os:getenv("HPR_PACKET_REPORTER_LOCAL_PORT", [])
        }
    of
        {[], _} ->
            {skip, env_host_empty};
        {_, []} ->
            {skip, env_post_empty};
        _ ->
            test_utils:init_per_testcase(TestCase, Config)
    end.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    %% Empty bucket for next test
    State = sys:get_state(hpr_packet_reporter),
    AWSClient = hpr_packet_reporter:get_client(State),
    Bucket = hpr_packet_reporter:get_bucket(State),
    {ok, #{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    Keys =
        case erlang:is_map(Contents) of
            true ->
                [maps:get(<<"Key">>, Contents)];
            false ->
                [maps:get(<<"Key">>, Content) || Content <- Contents]
        end,
    {ok, _, _} = aws_s3:delete_objects(
        AWSClient, Bucket, #{
            <<"Body">> => #{
                <<"Delete">> => [
                    #{<<"Object">> => #{<<"Key">> => Key}}
                 || Key <- Keys
                ]
            }
        }
    ),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

upload_test(_Config) ->
    %% Send N packets
    N = 100,
    OUI = 1,
    NetID = 2,
    Route = hpr_route:test_new(#{
        id => "test-route",
        oui => OUI,
        net_id => NetID,
        devaddr_ranges => [],
        euis => [],
        max_copies => 1,
        nonce => 1,
        server => #{host => "example.com", port => 8080, protocol => undefined}
    }),
    ExpectedPackets = lists:map(
        fun(X) ->
            Time = erlang:system_time(millisecond),
            Packet = test_utils:uplink_packet_up(#{rssi => X}),
            hpr_packet_reporter:report_packet(
                Packet, Route, false, Time
            ),
            hpr_packet_report:new(Packet, Route, false, Time)
        end,
        lists:seq(1, N)
    ),

    %% Wait until packets are all in state
    ok = test_utils:wait_until(
        fun() ->
            State = sys:get_state(hpr_packet_reporter),
            N == erlang:length(erlang:element(7, State))
        end
    ),

    State = sys:get_state(hpr_packet_reporter),
    AWSClient = hpr_packet_reporter:get_client(State),
    Bucket = hpr_packet_reporter:get_bucket(State),

    %% Check that bucket is still empty
    {ok, #{<<"ListBucketResult">> := ListBucketResult0}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    ?assertNot(maps:is_key(<<"Contents">>, ListBucketResult0)),

    %% Force upload
    hpr_packet_reporter ! upload,

    %% Wait unitl bucket report not empty
    ok = test_utils:wait_until(
        fun() ->
            {ok, #{<<"ListBucketResult">> := ListBucketResult}, _} = aws_s3:list_objects(
                AWSClient, Bucket
            ),
            maps:is_key(<<"Contents">>, ListBucketResult)
        end
    ),

    %% Check file name
    {ok, #{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} = aws_s3:list_objects(
        AWSClient, Bucket
    ),
    FileName = maps:get(<<"Key">>, Contents),
    [Prefix, Timestamp, Ext] = binary:split(FileName, <<".">>, [global]),
    ?assertEqual(<<"packetreport">>, Prefix),
    ?assert(erlang:binary_to_integer(Timestamp) < erlang:system_time(millisecond)),
    ?assert(
        erlang:binary_to_integer(Timestamp) > erlang:system_time(millisecond) - timer:seconds(2)
    ),
    ?assertEqual(<<"gz">>, Ext),

    %% Get file content and check that all packets are there
    {ok, #{<<"Body">> := Compressed}, _} = aws_s3:get_object(AWSClient, Bucket, FileName),
    ExtractedPackets = extract_packets(Compressed),
    ?assertEqual(lists:sort(ExpectedPackets), lists:sort(ExtractedPackets)),

    timer:sleep(100),
    ?assertNotEqual(
        undefined,
        prometheus_histogram:value(?METRICS_PACKET_REPORT_HISTOGRAM, [ok])
    ),

    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

-spec extract_packets(Compressed :: binary()) -> [hpr_packet_report:packet_report()].
extract_packets(Compressed) ->
    UnCompressed = zlib:gunzip(Compressed),
    extract_packets(UnCompressed, []).

-spec extract_packets(Rest :: binary(), Acc :: [hpr_packet_report:packet_report()]) ->
    [hpr_packet_report:packet_report()].
extract_packets(<<>>, Acc) ->
    Acc;
extract_packets(<<Size:32/big-integer-unsigned, Rest/binary>>, Acc) ->
    <<EncodedPacket:Size/binary, Rest2/binary>> = Rest,
    Packet = hpr_packet_report:decode(EncodedPacket),
    extract_packets(Rest2, [Packet | Acc]).
