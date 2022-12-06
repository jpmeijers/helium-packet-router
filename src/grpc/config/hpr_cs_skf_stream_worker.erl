%%%-------------------------------------------------------------------
%% @doc
%% === Config Service Session Key Filter Worker ===
%%
%% Same as `hpr_cs_route_stream_worker' but for Session Key Filters.
%% Go see the other module for some notes about failure modes.
%%
%% @end
%%%-------------------------------------------------------------------
-module(hpr_cs_skf_stream_worker).

-behaviour(gen_server).

-include("hpr.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-ifdef(TEST).
-define(BACKOFF_MIN, timer:seconds(1)).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    stream :: grpcbox_client:stream() | undefined,
    conn_backoff :: backoff:backoff()
}).

-define(SERVER, ?MODULE).
-define(INIT_STREAM, init_stream).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(map()) -> any().
start_link(Args) ->
    gen_server:start_link(
        {local, ?SERVER}, ?SERVER, Args, []
    ).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    lager:info("starting session key filter worker"),
    self() ! ?INIT_STREAM,
    {ok, #state{
        stream = undefined,
        conn_backoff = Backoff
    }}.

handle_call(Msg, _From, State) ->
    {stop, {unimplemented_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unimplemented_cast, Msg}, State}.

handle_info(?INIT_STREAM, #state{conn_backoff = Backoff0} = State) ->
    lager:info("connecting"),
    {PubKey, SigFun} = persistent_term:get(?HPR_KEY),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    SKFStreamReq = hpr_skf_stream_req:new(PubKeyBin),
    SignedSKFStreamReq = hpr_skf_stream_req:sign(SKFStreamReq, SigFun),
    SignedSKFStreamReqMap = hpr_skf_stream_req:to_map(SignedSKFStreamReq),
    StreamOptions = #{channel => config_channel},

    case helium_config_session_key_filter_client:stream(SignedSKFStreamReqMap, StreamOptions) of
        {ok, Stream} ->
            lager:info("stream initialized"),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{stream = Stream, conn_backoff = Backoff1}};
        {error, undefined_channel} ->
            lager:error(
                "`config_channel` is not defined, or not started. Not attempting to reconnect."
            ),
            {noreply, State};
        {error, _E} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:error("failed to get stream sleeping ~wms", [Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
%% GRPC stream callbacks
handle_info({data, _StreamID, SKFStreamRes}, State) ->
    lager:debug("sfk update"),
    ok = process_res(hpr_skf_stream_res:from_map(SKFStreamRes)),
    {noreply, State};
handle_info({headers, _StreamID, _Headers}, State) ->
    %% noop on headers
    {noreply, State};
handle_info({trailers, _StreamID, Trailers}, State) ->
    %% IF a stream is closed by the server side, Trailers will be
    %% received before the EOS. Removing the stream from state will
    %% mean none of the other clauses match, and reconnecting will not
    %% be attempted.
    %% ref: https://grpc.github.io/grpc/core/md_doc_statuscodes.html
    case Trailers of
        {<<"12">>, _, _} ->
            lager:error(
                "helium.config.session_key_filter/stream not implemented. "
                "Make sure you're pointing at the right server."
            ),
            {noreply, State#state{stream = undefined}};
        _ ->
            {noreply, State}
    end;
handle_info(
    {eos, StreamID},
    #state{stream = #{stream_id := StreamID}, conn_backoff = Backoff0} = State
) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    lager:info("stream went down sleeping ~wms", [Delay]),
    _ = erlang:send_after(Delay, self(), ?INIT_STREAM),
    {noreply, State#state{stream = undefined, conn_backoff = Backoff1}};
handle_info(_Msg, State) ->
    lager:warning("unimplemented_info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec process_res(
    SKFStreamRes :: hpr_skf_stream_res:res()
) -> ok.
process_res(SKFStreamRes) ->
    SKF = hpr_skf_stream_res:filter(SKFStreamRes),
    case hpr_skf_stream_res:action(SKFStreamRes) of
        delete ->
            hpr_skf_ets:delete(SKF);
        _ ->
            hpr_skf_ets:insert(SKF)
    end.
