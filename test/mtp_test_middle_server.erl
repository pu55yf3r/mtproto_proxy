%% @doc Fake telegram "middle-proxy" server
-module(mtp_test_middle_server).
-behaviour(ranch_protocol).
-behaviour(gen_statem).

-export([start/2,
         stop/1]).
-export([start_link/4,
         ranch_init/1]).
-export([init/1,
         callback_mode/0,
         %% handle_call/3,
         %% handle_cast/2,
         %% handle_info/2,
         code_change/3,
         terminate/2
        ]).
-export([wait_nonce/3,
         wait_handshake/3,
         on_tunnel/3]).

-record(hs_state,
        {sock,
         transport,
         secret,
         codec :: mtp_codec:codec(),
         cli_nonce,
         cli_ts,
         sender_pid,
         peer_pid,
         srv_nonce}).
-record(t_state,
        {sock,
         transport,
         codec,
         clients = #{} :: #{}}).

-define(RPC_NONCE, 170,135,203,122).
-define(RPC_HANDSHAKE, 245,238,130,118).
-define(RPC_FLAGS, 0, 0, 0, 0).

%% -type state_name() :: wait_nonce | wait_handshake | on_tunnel.

%% Api
start(Id, Opts) ->
    {ok, _} = application:ensure_all_started(ranch),
    ranch:start_listener(
      Id, ranch_tcp,
      #{socket_opts => [{ip, {127, 0, 0, 1}},
                        {port, maps:get(port, Opts)}],
        num_acceptors => 2,
        max_connections => 100},
      ?MODULE, Opts).

stop(Id) ->
    ranch:stop_listener(Id).

%% Callbacks

start_link(Ref, _, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, ranch_init, [{Ref, Transport, Opts}])}.

ranch_init({Ref, Transport, Opts}) ->
    {ok, Socket} = ranch:handshake(Ref),
    {ok, StateName, StateData} = init({Socket, Transport, Opts}),
    ok = Transport:setopts(Socket, [{active, once}]),
    gen_statem:enter_loop(?MODULE, [], StateName, StateData).

init({Socket, Transport, Opts}) ->
    Codec = mtp_codec:new(mtp_noop_codec, mtp_noop_codec:new(),
                          mtp_full, mtp_full:new(-2, -2)),
    {ok, wait_nonce, #hs_state{sock = Socket,
                               transport = Transport,
                               secret = maps:get(secret, Opts),
                               codec = Codec}}.

callback_mode() ->
    state_functions.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% State handlers
%%

wait_nonce(info, {tcp, _Sock, TcpData},
           #hs_state{codec = Codec0, secret = Key,
                     transport = Transport, sock = Sock} = S) ->
    %% Hope whole protocol packet fit in 1 TCP packet
    {ok, PacketData, Codec1} = mtp_codec:try_decode_packet(TcpData, Codec0),
    <<KeySelector:4/binary, _/binary>> = Key,
    {nonce, KeySelector, Schema, CryptoTs, CliNonce} = mtp_rpc:decode_nonce(PacketData),
    SrvNonce = crypto:strong_rand_bytes(16),
    Answer = mtp_rpc:encode_nonce({nonce, KeySelector, Schema, CryptoTs, SrvNonce}),
    %% Send non-encrypted nonce
    {ok, #hs_state{codec = Codec2} = S1} = hs_send(Answer, S#hs_state{codec = Codec1}),
    %% Generate keys
    {ok, {CliIp, CliPort}} = Transport:peername(Sock),
    {ok, {MyIp, MyPort}} = Transport:sockname(Sock),
    CliIpBin = mtp_obfuscated:bin_rev(mtp_rpc:inet_pton(CliIp)),
    MyIpBin = mtp_obfuscated:bin_rev(mtp_rpc:inet_pton(MyIp)),

    Args = #{srv_n => SrvNonce, clt_n => CliNonce, clt_ts => CryptoTs,
             srv_ip => MyIpBin, srv_port => MyPort,
             clt_ip => CliIpBin, clt_port => CliPort, secret => Key},
    {DecKey, DecIv} = mtp_down_conn:get_middle_key(Args#{purpose => <<"CLIENT">>}),
    {EncKey, EncIv} = mtp_down_conn:get_middle_key(Args#{purpose => <<"SERVER">>}),
    %% Add encryption layer to codec
    {_, _, PacketMod, PacketState} = mtp_codec:decompose(Codec2),
    CryptoState = mtp_aes_cbc:new(EncKey, EncIv, DecKey, DecIv, 16),
    Codec3 = mtp_codec:new(mtp_aes_cbc, CryptoState,
                           PacketMod, PacketState),

    {next_state, wait_handshake,
     activate(S1#hs_state{codec = Codec3,
                          cli_nonce = CliNonce,
                          cli_ts = CryptoTs,
                          srv_nonce = SrvNonce})};
wait_nonce(Type, Event, S) ->
    handle_event(Type, Event, ?FUNCTION_NAME, S).


wait_handshake(info, {tcp, _Sock, TcpData},
               #hs_state{codec = Codec0} = S) ->
    {ok, PacketData, Codec1} = mtp_codec:try_decode_packet(TcpData, Codec0),
    {handshake, SenderPID, PeerPID} = mtp_rpc:decode_handshake(PacketData),
    Answer = mtp_rpc:encode_handshake({handshake, SenderPID, PeerPID}),
    {ok, #hs_state{sock = Sock,
                   transport = Transport,
                   codec = Codec2}} = hs_send(Answer, S#hs_state{codec = Codec1}),
    {next_state, on_tunnel,
     activate(#t_state{sock = Sock,
                       transport = Transport,
                       codec = Codec2,
                       clients = #{}})};
wait_handshake(Type, Event, S) ->
    handle_event(Type, Event, ?FUNCTION_NAME, S).


on_tunnel(info, {tcp, _Sock, TcpData}, #t_state{codec = Codec0} = S) ->
    {ok, S2, Codec1} =
        mtp_codec:fold_packets(
          fun(Packet, S1, Codec1) ->
                  S2 = handle_rpc(mtp_rpc:srv_decode_packet(Packet), S1#t_state{codec = Codec1}),
                  {S2, S2#t_state.codec}
          end, S, TcpData, Codec0),
    {keep_state, activate(S2#t_state{codec = Codec1})};
on_tunnel(Type, Event, S) ->
    handle_event(Type, Event, ?FUNCTION_NAME, S).

handle_event(info, {tcp_closed, _Sock}, _EventName, _S) ->
    {stop, normal}.

%% Helpers

hs_send(Packet, #hs_state{transport = Transport, sock = Sock,
                          codec = Codec} = St) ->
    %% lager:debug("Up>Down: ~w", [Packet]),
    {Encoded, Codec1} = mtp_codec:encode_packet(Packet, Codec),
    ok = Transport:send(Sock, Encoded),
    {ok, St#hs_state{codec = Codec1}}.

t_send(Packet, #t_state{transport = Transport, sock = Sock,
                        codec = Codec} = St) ->
    %% lager:debug("Up>Down: ~w", [Packet]),
    {Encoded, Codec1} = mtp_codec:encode_packet(Packet, Codec),
    ok = Transport:send(Sock, Encoded),
    {ok, St#t_state{codec = Codec1}}.

activate(#hs_state{transport = Transport, sock = Sock} = S) ->
    ok = Transport:setopts(Sock, [{active, once}]),
    S;
activate(#t_state{transport = Transport, sock = Sock} = S) ->
    ok = Transport:setopts(Sock, [{active, once}]),
    S.

handle_rpc({data, ConnId, Data}, #t_state{clients = Clients} = S) ->
    %% Echo data back
    %% TODO: interptet Data to power some test scenarios, eg, client might
    %% ask to close it's connection
    {ok, S1} = t_send(mtp_rpc:srv_encode_packet({proxy_ans, ConnId, Data}), S),
    Cnt = maps:get(ConnId, Clients, 0),
    %% Increment can fail if there is a tombstone for this client
    S1#t_state{clients = Clients#{ConnId => Cnt + 1}};
handle_rpc({remote_closed, ConnId}, #t_state{clients = Clients} = S) ->
    is_integer(maps:get(ConnId, Clients))
        orelse error({unexpected_closed, ConnId}),
    S#t_state{clients = Clients#{ConnId := tombstone}}.
