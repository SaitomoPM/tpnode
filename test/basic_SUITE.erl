-module(basic_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%-define(TESTNET_NODES, [
%%    "test_c4n1",
%%    "test_c4n2",
%%    "test_c4n3",
%%    "test_c5n1",
%%    "test_c5n2",
%%    "test_c5n3"
%%]).

-define(TESTNET_NODES, [
    "test_c4n1",
    "test_c4n2",
    "test_c4n3"
]).


all() ->
    [
        register_wallet_test,
        discovery_got_announce_test,
        discovery_register_test,
        discovery_lookup_test,
        discovery_unregister_by_name_test,
        discovery_unregister_by_pid_test
    ].

init_per_suite(Config) ->
%%    Env = os:getenv(),
%%    io:fwrite("env ~p", [Env]),
%%    io:fwrite("w ~p", [os:cmd("which erl")]),
    ok = wait_for_testnet(60),
%%    Config ++ [{processes, Pids}].
    Config.

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

end_per_suite(Config) ->
%%    Pids = proplists:get_value(processes, Config, []),
%%    lists:foreach(
%%        fun(Pid) ->
%%            io:fwrite("Killing ~p~n", [Pid]),
%%            exec:kill(Pid, 15)
%%        end, Pids),
    Config.


%%get_node_cmd(Name) when is_list(Name) ->
%%    "erl -progname erl -config " ++ Name ++ ".config -sname "++ Name ++ " -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s tpnode".
%%%%    "sleep 1000".

%%run_testnet_nodes() ->
%%    exec:start([]),
%%
%%    io:fwrite("my name: ~p", [erlang:node()]),
%%
%%    Pids = lists:foldl(
%%        fun(NodeName, StartedPids) ->
%%            Cmd = get_node_cmd(NodeName),
%%            {ok, _Pid, OsPid} = exec:run_link(Cmd, []),
%%
%%            io:fwrite("Started node ~p with os pid ~p", [NodeName, OsPid]),
%%            [OsPid | StartedPids]
%%        end, [], ?TESTNET_NODES
%%    ),
%%    ok = wait_for_testnet(Pids),
%%    {ok, Pids}.


get_node(Name) when is_atom(Name) ->
    get_node(atom_to_list(Name));

get_node(Name) when is_list(Name) ->
    get_node(list_to_binary(Name));

get_node(Name) when is_binary(Name) ->
    [_,NodeHost]=binary:split(atom_to_binary(erlang:node(),utf8),<<"@">>),
    binary_to_atom(<<Name/binary, "@", NodeHost/binary>>, utf8).


wait_for_testnet(Trys) ->
    NodesCount = length(?TESTNET_NODES),
    Alive = lists:foldl(
        fun(Name, ReadyNodes) ->
            NodeName = get_node(Name),
            case net_adm:ping(NodeName) of
                pong ->
                    ReadyNodes + 1;
                _Answer ->
                    io:fwrite("Node ~p answered ~p~n", [NodeName, _Answer]),
                    ReadyNodes
            end
        end, 0, ?TESTNET_NODES),

    if
        Trys<1 ->
            timeout;
        Alive =/= NodesCount ->
            io:fwrite("testnet hasn't started yet, alive ~p, need ~p", [Alive, NodesCount]),
            timer:sleep(1000),
            wait_for_testnet(Trys-1);
        true -> ok
    end.


discovery_register_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    Answer = gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    ?assertEqual(ok, Answer).


discovery_lookup_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertMatch({ok, _, <<"test_service">>}, Result1),
    Result2 = gen_server:call(DiscoveryPid, {lookup, <<"nonexist">>}),
    ?assertEqual([], Result2),
    Result3 = gen_server:call(DiscoveryPid, {lookup, <<"tpicpeer">>}),
    ?assertNotEqual(0, length(Result3)).


discovery_unregister_by_name_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    gen_server:call(DiscoveryPid, {register, <<"test_service2">>, self()}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({ok, self(), <<"test_service">>}, Result1),
    gen_server:call(DiscoveryPid, {unregister, <<"test_service">>}),
    Result2 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({error,not_found,<<"test_service">>}, Result2),
    Result3 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({ok, self(), <<"test_service2">>}, Result3).


discovery_unregister_by_pid_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    MyPid = self(),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, MyPid}),
    gen_server:call(DiscoveryPid, {register, <<"test_service2">>, MyPid}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({ok, MyPid, <<"test_service">>}, Result1),
    Result2 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({ok, MyPid, <<"test_service2">>}, Result2),
    gen_server:call(DiscoveryPid, {unregister, MyPid}),
    Result3 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({error, not_found, <<"test_service">>}, Result3),
    Result4 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({error, not_found, <<"test_service2">>}, Result4).


% build announce as c4n3
build_announce(Name) ->
    Now = os:system_time(second),
    Announce = #{
        name => Name,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => api},
        created => Now,
        ttl => 600,
        scopes => [api, xchain],
        nodeid => <<"28AFpshz4W4YD7tbLj1iu4ytpPzQ">>, % id from c4n3
        chain => 4
    },
    meck:new(nodekey),
    % priv key from c4n3 node
    meck:expect(nodekey, get_priv, fun() -> hex:parse("2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0") end),
    AnnounceBin = discovery:pack(Announce),
    meck:unload(nodekey),
    {Announce, AnnounceBin}.


discovery_got_announce_test(_Config) ->
    DiscoveryC4N1 = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    DiscoveryC4N2 = rpc:call(get_node(<<"test_c4n2">>), erlang, whereis, [discovery]),
    DiscoveryC4N3 = rpc:call(get_node(<<"test_c4n3">>), erlang, whereis, [discovery]),
    DiscoveryC5N2 = rpc:call(get_node(<<"test_c5n2">>), erlang, whereis, [discovery]),
    Rnd = integer_to_binary(rand:uniform(100000)),
    ServiceName = <<"looking_glass_", Rnd/binary>>,
    {_Announce, AnnounceBin} = build_announce(ServiceName),
    gen_server:cast(DiscoveryC4N1, {got_announce, AnnounceBin}),
    timer:sleep(2000),  % wait for announce propagation
    Result = gen_server:call(DiscoveryC4N1, {lookup, ServiceName, 4}),
    Experted = [#{address => <<"127.0.0.1">>,port => 1234, proto => api}],
    ?assertEqual(Experted, Result),
    % c4n1 should forward the announce to c4n2
    Result1 = gen_server:call(DiscoveryC4N2, {lookup, ServiceName, 4}),
    ?assertEqual(Experted, Result1),
    Result2 = gen_server:call(DiscoveryC4N2, {lookup, ServiceName, 5}),
    ?assertEqual([], Result2),
    % c4n3 should discard self announce
    Result3 = gen_server:call(DiscoveryC4N3, {lookup, ServiceName, 4}),
    ?assertEqual([], Result3),
    % c5n2 should get info from xchain announce
    Result4 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 4}),
    ?assertEqual(Experted, Result4),
    Result5 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 5}),
    ?assertEqual([], Result5).


get_tx_status(TxId, BaseUrl) when is_binary(TxId) andalso is_list(BaseUrl) ->
    get_tx_status(TxId, BaseUrl, 60);

get_tx_status(_TxId, _BaseUrl) ->
    badarg.

get_tx_status(_TxId, _BaseUrl, 0 = _Try) ->
    {ok, timeout, 0};

get_tx_status(TxId, BaseUrl, Try)->
    Query = {BaseUrl ++ "/api/tx/status/" ++ binary_to_list(TxId), []},
    {ok, {{_, 200, _}, _, ResBody}} = httpc:request(get, Query, [], [{body_format, binary}]),
    Res = jsx:decode(ResBody, [return_maps]),
    Status = maps:get(<<"res">>, Res, null),
    io:format("got tx status: ~p ~n * raw: ~p", [Status, Res]),
    case Status of
        null ->
            timer:sleep(1000),
            get_tx_status(TxId, BaseUrl, Try-1);
        AnyValidStatus ->
            {ok, AnyValidStatus, Try}
    end.

register_wallet_test(_Config) ->
    PrivKey = address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
    Promo = <<"TEST5">>,
    PubKey = tpecdsa:calc_pub(PrivKey, true),
    Now = os:system_time(second),
    TX0 = tx:pack(#{
        type=>register,
        register=>PubKey,
        timestamp=>Now,
        pow=>scratchpad:mine_sha512(<<Promo/binary, " ", (integer_to_binary(Now))/binary, " ">>, 0, 8)
    }),
    B64TX = base64:encode(TX0),
    Body = jsx:encode(#{
        tx=>B64TX
    }),
    % TODO: to get real http address from discovery
    Url = "http://pwr.local:49811",
    Query = {Url ++ "/api/tx/new", [], "application/json", Body},
    {ok, {{_, 200, _}, _, ResBody}} = httpc:request(post, Query, [], [{body_format, binary}]),
    Res = jsx:decode(ResBody, [return_maps]),
    ?assertEqual(<<"ok">>, maps:get(<<"result">>, Res, unknown)),
    TxId = maps:get(<<"txid">>, Res, unknown),
    ?assertNotEqual(unknown, TxId),
    io:format("got txid: ~p~n~p~n", [TxId, ResBody]),
    ?assertMatch(#{<<"result">> := <<"ok">>}, Res),
    {ok, Status, _TrysLeft} = get_tx_status(TxId, Url),
    io:format("transaction status: ~p ~n trys left: ~p", [Status, _TrysLeft]),
    ?assertNotEqual(timeout, Status),
    ?assertMatch(#{<<"ok">> := true}, Status),
    Wallet = maps:get(<<"res">>, Status, unknown),
    ?assertNotEqual(unknown, Wallet),
    % проверяем статус кошелька через API
    Query2 = {Url ++ "/api/address/" ++ binary_to_list(Wallet), []},
    {ok, {{_, 200, _}, _, ResBody2}} = httpc:request(get, Query2, [], [{body_format, binary}]),
    Res2 = jsx:decode(ResBody2, [return_maps]),
    io:format("Info for wallet ~p: ~p", [Wallet, Res2]),
    ?assertMatch(#{<<"result">> := <<"ok">>, <<"txtaddress">> := Wallet}, Res2),
    WalletInfo = maps:get(<<"info">>, Res2, unknown),
    ?assertNotEqual(unknown, WalletInfo),
    PubKeyFromAPI = maps:get(<<"pubkey">>, WalletInfo, unknown),
    ?assertNotEqual(unknown, PubKeyFromAPI).

