-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-compile(nowarn_export_all).
%-compile(export_all).
-endif.

-export([start_link/0]).


%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, #{
       nodeid=>nodekey:node_id(),
       preptxl=>[],
       settings=>#{}
      }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin) of
        {ok, Struct} ->
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            lager:info("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
           <<"hash">> := ParentHash,
           <<"signed">> := SignedBy
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  lager:debug("MB presig got ~s ~p", [Origin, SignedBy]),
  if Origin==false ->
       {noreply, State};
     true ->
       PreSig=maps:get(presig, State, #{}),
       {noreply,
      State#{
        presig=>maps:put(Origin, {ParentHash, SignedBy}, PreSig)
       }}
  end;

handle_cast({tpic, Origin, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"txs">>:=TPICTXs
                    }}, State)  ->
  TXs=decode_tpic_txs(TPICTXs),
  if TXs==[] -> ok;
     true ->
       lager:info("Got txs from ~s: ~p",
            [
             chainsettings:is_our_node(Origin),
             TXs
            ])
  end,
  handle_cast({prepare, Origin, TXs}, State);

handle_cast({prepare, Node, Txs}, #{preptxl:=PreTXL}=State) ->
  Origin=chainsettings:is_our_node(Node),
  if Origin==false ->
       lager:error("Got txs from bad node ~s",
             [bin2hex:dbin2hex(Node)]),
       {noreply, State};
     true ->
       if Txs==[] -> ok;
        true ->
          lager:info("TXs from node ~s: ~p",
               [ Origin, length(Txs) ])
       end,
       MarkTx=fun({TxID, TxB}) ->
              TxB1=try
                     case TxB of
                       #{patch:=_} ->
                         VerFun=fun(PubKey) ->
                                    NodeID=chainsettings:is_our_node(PubKey),
                                    is_binary(NodeID)
                                end,
                         {ok, Tx1} = settings:verify(TxB, VerFun),
                         tx:set_ext(origin, Origin, Tx1);
                       #{ hash:=_,
                          header:=_,
                          sign:=_} ->
                         %do nothing with inbound block
                         TxB;
                       _ ->
                         {ok, Tx1} = tx:verify(TxB),
                         tx:set_ext(origin, Origin, Tx1)
                     end
                 catch _Ec:_Ee ->
                     S=erlang:get_stacktrace(),
                     lager:error("Error ~p:~p", [_Ec, _Ee]),
                     lists:foreach(fun(SE) ->
                                 lager:error("@ ~p", [SE])
                             end, S),
                     file:write_file("tmp/mkblk_badsig_" ++ binary_to_list(nodekey:node_id()),
                             io_lib:format("~p.~n", [TxB])),

                     TxB
                 end,
              {TxID,TxB1}
          end,
       {noreply,
      case maps:get(parent, State, undefined) of
        undefined ->
          #{header:=#{height:=Last_Height}, hash:=Last_Hash}=gen_server:call(blockchain, last_block),
          State#{
            preptxl=>PreTXL ++ lists:map(MarkTx, Txs),
            parent=>{Last_Height, Last_Hash}
           };
        _ ->
          State#{ preptxl=>PreTXL ++ lists:map(MarkTx, Txs) }
      end
       }
  end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("MB unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(process, #{settings:=#{mychain:=MyChain}=MySet, preptxl:=PreTXL0}=State) ->
  lager:info("-------[MAKE BLOCK]-------"),
  PreTXL1=lists:foldl(
            fun({TxID, TXB}, Acc) ->
                case maps:is_key(TxID, Acc) of
                  true ->
                    TXB1=tx:mergesig(TXB,
                                     maps:get(TxID, Acc)),
                    {ok, Tx1} = tx:verify(TXB1),
                    maps:put(TxID, Tx1, Acc);
                  false ->
                    maps:put(TxID, TXB, Acc)
                end
            end, #{}, PreTXL0),
  PreTXL=lists:keysort(1, maps:to_list(PreTXL1)),

  AE=maps:get(ae, MySet, 1),

  {_, ParentHash}=Parent=case maps:get(parent, State, undefined) of
                           undefined ->
                             lager:info("Fetching last block from blockchain"),
                             #{header:=#{height:=Last_Height1}, hash:=Last_Hash1}=gen_server:call(blockchain, last_block),
                             {Last_Height1, Last_Hash1};
                           {A, B} -> {A, B}
                         end,

  PreNodes=try
             PreSig=maps:get(presig, State),
             BK=maps:fold(
                  fun(_, {BH, _}, Acc) when BH =/= ParentHash ->
                      Acc;
                     (Node1, {_BH, Nodes2}, Acc) ->
                      [{Node1, Nodes2}|Acc]
                  end, [], PreSig),
             lists:sort(bron_kerbosch:max_clique(BK))
           catch Ec:Ee ->
                   Stack1=erlang:get_stacktrace(),
                   lager:error("Can't calc xsig ~p:~p ~p", [Ec, Ee, Stack1]),
                   []
           end,

  try
    if(AE==0 andalso PreTXL==[]) -> throw(empty);
      true -> ok
    end,
    T1=erlang:system_time(),
    lager:debug("MB pre nodes ~p", [PreNodes]),

    PropsFun=fun(mychain) ->
                 MyChain;
                (settings) ->
                 blockchain:get_settings();
                ({valid_timestamp, TS}) ->
                 abs(os:system_time(millisecond)-TS)<3600000;
                ({endless, From, Cur}) ->
                 EndlessPath=[<<"current">>, <<"endless">>, From, Cur],
                 case blockchain:get_settings(EndlessPath) of
                   true -> true;
                   _ ->
                     % TODO 2018-05-01: Replace this code with false
                     Endless=lists:member(
                               From,
                               application:get_env(tpnode, endless, [])
                              ),
                     if Endless ->
                          lager:notice("Deprecated: issue tokens by address in config");
                        true ->
                          ok
                     end,
                     Endless
                 end;
                ({get_block, Back}) when 32>=Back ->
                 FindBlock=fun FB(H, N) ->
                 case gen_server:call(blockchain, {get_block, H}) of
                   undefined ->
                     undefined;
                   #{header:=#{parent:=P}}=Blk ->
                     if N==0 ->
                          maps:without([bals, txs], Blk);
                        true ->
                          FB(P, N-1)
                     end
                 end
             end,
    FindBlock(last, Back)
  end,
  AddrFun=fun({Addr, _Cur}) ->
              case ledger:get(Addr) of
                #{amount:=_}=Bal -> Bal;
                not_found -> bal:new()
              end;
             (Addr) ->
              case ledger:get(Addr) of
                #{amount:=_}=Bal -> Bal;
                not_found -> bal:new()
              end
          end,

  #{block:=Block,
    failed:=Failed,
    emit:=EmitTXs}=generate_block:generate_block(PreTXL, Parent, PropsFun, AddrFun,
                                                 [{<<"prevnodes">>, PreNodes}]),
  T2=erlang:system_time(),
  if Failed==[] ->
       ok;
     true ->
       %there was failed tx. Block empty?
       gen_server:cast(txpool, {failed, Failed}),
       if(AE==0) ->
           case maps:get(txs, Block, []) of
             [] -> throw(empty);
             _ -> ok
           end;
         true ->
           ok
       end
  end,
  Timestamp=os:system_time(millisecond),
  ED=[
      {timestamp, Timestamp},
      {createduration, T2-T1}
     ],
  SignedBlock=sign(Block, ED),
  #{header:=#{height:=NewH}}=Block,
  %cast whole block for my local blockvote
  gen_server:cast(blockvote, {new_block, SignedBlock, self()}),

  case application:get_env(tpnode, dumpblocks) of
    {ok, true} ->
      file:write_file("tmp/mkblk_" ++
                      integer_to_list(NewH) ++ "_" ++
                      binary_to_list(nodekey:node_id()),
                      io_lib:format("~p.~n", [SignedBlock])
                     );
    _ -> ok
  end,
  %Block signature for each other
  lager:info("MB My sign ~p emit ~p",
             [
              maps:get(sign, SignedBlock),
              length(EmitTXs)
             ]),
  HBlk=msgpack:pack(
         #{null=><<"blockvote">>,
           <<"n">>=>node(),
           <<"hash">>=>maps:get(hash, SignedBlock),
           <<"sign">>=>maps:get(sign, SignedBlock),
           <<"chain">>=>MyChain
          }
        ),
  tpic:cast(tpic, <<"blockvote">>, HBlk),
  if EmitTXs==[] -> ok;
     true ->
       lager:info("Inject TXs ~p", [
                                    gen_server:call(txpool, {push_etx, EmitTXs})
                                   ])
  end,
  {noreply, State#{preptxl=>[], parent=>undefined, presig=>#{}}}
catch throw:empty ->
        lager:info("Skip empty block"),
        {noreply, State#{preptxl=>[], parent=>undefined, presig=>#{}}}
    end;

handle_info(process, State) ->
    lager:notice("MKBLOCK Blocktime, but I not ready"),
    {noreply, load_settings(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

sign(Blk, ED) when is_map(Blk) ->
    PrivKey=nodekey:get_priv(),
    block:sign(Blk, ED, PrivKey).

load_settings(State) ->
    OldSettings=maps:get(settings, State, #{}),
    MyChain=blockchain:chain(),
    AE=blockchain:get_mysettings(allowempty),
    State#{
      settings=>maps:merge(
                  OldSettings,
                  #{ae=>AE, mychain=>MyChain}
                 )
     }.

decode_tpic_txs(TXs) ->
    lists:map(
      fun({TxID, Tx}) ->
              {TxID, tx:unpack(Tx)}
      end, maps:to_list(TXs)).

