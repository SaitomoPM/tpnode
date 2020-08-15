-module(tpnode_txstorage).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([get_tx/1, get_tx/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
  Name=maps:get(name,Args,txstorage),
  gen_server:start_link({local, Name}, ?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init_table(EtsTableName) ->
  Table =
    ets:new(
      EtsTableName,
      [named_table, protected, set, {read_concurrency, true}]
    ),
  lager:info("Table created: ~p", [Table]).

init(Args) ->
  EtsTableName = maps:get(ets_name, Args, txstorage),
  init_table(EtsTableName),
  {ok, #{
    expire_tick_ms => 1000 * maps:get(expire_check_sec, Args, 60), % default: 1 minute
    timer_expire => erlang:send_after(10*1000, self(), timer_expire), % first timer fires after 10 seconds
    ets_name => EtsTableName,
    my_ttl => maps:get(my_ttl, Args, 30*60),  % default: 30 min
    ets_ttl_sec => maps:get(ets_ttl_sec, Args, 20*60)  % default: 20 min
  }}.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(get_table_name, _From, #{ets_name:=EtsName} = State) ->
  {reply, EtsName, State};

handle_call({new_tx, TxID, TxBin}, _From, State) ->
  case new_tx(TxID, TxBin, State) of
    {ok, S1} ->
      {reply, ok, S1};
    Any ->
      lager:error("Can't add tx: ~p",[Any]),
      {reply, {error, Any}, State}
  end;

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast({tpic, FromPubKey, Peer, PayloadBin}, State) ->
  lager:debug( "txstorage got txbatch from ~p payload ~p", [ FromPubKey, PayloadBin]),
  case msgpack:unpack(PayloadBin, [ {unpack_str, as_binary} ]) of
    {ok, MAP} ->
      case handle_tpic(MAP, FromPubKey, Peer, State) of
        {noreply, State1} ->
          {noreply, State1};
        {reply, Reply, State1} ->
          tpic2:cast(Peer, msgpack:pack(Reply)),
          {noreply, State1}
      end;
    _ ->
      lager:error("txstorage can't unpack msgpack: ~p", [ PayloadBin ]),
      {noreply, State}
  end;

handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(timer_expire,
  #{ets_name:=EtsName, timer_expire:=Tmr, expire_tick_ms:=Delay} = State) ->

  catch erlang:cancel_timer(Tmr),
  lager:debug("remove expired records"),
  Now = os:system_time(second),
  ets:select_delete(
    EtsName,
    [{{'_', '_', '_', '_', '$1'}, [{'<', '$1', Now}], [true]}]
  ),
  {noreply,
    State#{
      timer_expire => erlang:send_after(Delay, self(), timer_expire)
    }
  };

handle_info({txsync_done, true, TxID, Peers}, State) ->
  case update_tx_peers(TxID, Peers, State) of
    {ok, S1} ->
      lager:info("Tx ~p ready",[TxID]),
      gen_server:cast(txqueue, {push_tx, TxID}),
      {noreply, S1};
    Any ->
      lager:error("Can't update peers for tx ~p: ~p",[TxID,Any]),
      {noreply, State}
  end;

handle_info({txsync_done, false, TxID, _Peers}, State) ->
  lager:notice("Tx ~s sync failed, insufficient peers ~p",[TxID,_Peers]),
  gen_server:cast(txstatus, {done, false, [{TxID, insufficient_nodes_confirmed}]}),
  {noreply, State};

handle_info(_Info, State) ->
  lager:notice("Unknown info  ~p", [_Info]),
  {noreply, State}.

handle_tpic(#{ null := <<"txsync_refresh">>, <<"txid">> := TxID}, _, _From, State) ->
  case refresh_tx(TxID, State) of
    {ok, State2} ->
      {reply, #{
         null => <<"txsync_refresh_res">>,
         <<"res">> => <<"ok">>,
         <<"txid">> => TxID
        }, State2};
    not_found ->
      {reply, #{
         null => <<"txsync_refresh_res">>,
         <<"res">> => <<"error">>,
         <<"txid">> => TxID
        }, State}
  end;

handle_tpic(#{ null := <<"txsync_push">>, <<"txid">> := TxID, <<"body">> := TxBin}, FromPubKey, _Peer, State) ->
  case store_tx(TxID, TxBin, FromPubKey, State) of
    {ok, State2} ->
      {reply, #{
         null => <<"txsync_res">>,
         <<"res">> => <<"ok">>,
         <<"txid">> => TxID
        }, State2};
    {error, Reason} ->
      {reply, #{
         null => <<"txsync_res">>,
         <<"txid">> => TxID,
         <<"res">> => <<"error">>,
         <<"reason">> => Reason
        }, State}
  end;

handle_tpic(_, _, _, State) ->
  {reply, #{ null => <<"unknown_command">> }, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
update_tx_peers(TxID, Peers, #{ets_name:=Table} = State) ->
  case ets:lookup(Table, TxID) of
    [{TxID, TxBody, FromPeer, _, ValidUntil}] ->
      ets:insert(Table, {TxID, TxBody, FromPeer, Peers, ValidUntil}),
      {ok, State};
    [] ->
      not_found
  end.

refresh_tx(TxID, #{ets_ttl_sec:=TTL, ets_name:=Table} = State) ->
  case ets:lookup(Table, TxID) of
    [{TxID, TxBody, FromPeer, Nodes, _ValidUntil}] ->
      ValidUntil = os:system_time(second) + TTL,
      ets:insert(Table, {TxID, TxBody, FromPeer, Nodes, ValidUntil}),
      {ok, State};
    [] ->
      not_found
  end.

new_tx(TxID, TxBody, #{my_ttl:=TTL, ets_name:=Table} = State) ->
  ValidUntil = os:system_time(second) + TTL,
  ets:insert(Table, {TxID, TxBody, me, [], ValidUntil}),
  MS=chainsettings:by_path([<<"current">>,chain,minsig]),
  true=is_integer(MS),
  tpnode_txsync:synchronize(TxID, #{min_peers=>max(MS-1,0)}),
  {ok, State}.

store_tx(TxID, TxBody, FromPeer, #{ets_ttl_sec:=TTL, ets_name:=Table} = State) ->
  ValidUntil = os:system_time(second) + TTL,
  ets:insert(Table, {TxID, TxBody, FromPeer, [], ValidUntil}),
  {ok, State}.

get_tx(TxID) ->
  get_tx(TxID, txstorage).

get_tx(TxID, Table) ->
  case ets:lookup(Table, TxID) of
    [{TxID, Tx, _Origin, Nodes, _ValidUntil}] ->
      {ok, {TxID, Tx, Nodes}};
    [] ->
      error
  end.
