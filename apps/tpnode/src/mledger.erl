-module(mledger).
-compile({no_auto_import,[get/1]}).
-export([start_db/0,put/2,get/1,get_vers/1,hash/1]).
-export([bi_create/6,bi_set_ver/2]).
-export([bals2patch/1, apply_patch/2]).
-export([dbmtfun/3]).

-record(bal_items,
        {
         addr_key_ver_path,
         address,version,key,path,introduced,value,
         addr_ver, addr_key
        }).
tables() ->
  [bal_items,bal_tree,ledger_tree].

ensure_tables([]) ->
  [];

ensure_tables([E|Rest]) ->
  try
    true=is_list(mnesia:table_info(E,attributes)),
    ensure_tables(Rest)
  catch exit: {aborted,{no_exists,_,attributes}} ->
          [{E,create_table(E)} | ensure_tables(Rest)]
  end.

table_descr(bal_items) ->
  {[
    {attributes,record_info(fields, bal_items)},
    {rocksdb_copies, [node()]}
   ],[addr_ver, addr_key],
   undefined};

table_descr(bal_tree) ->
  {[
    {attributes,[key,value]},
    {rocksdb_copies, [node()]}
   ],[],
   undefined};

table_descr(ledger_tree) ->
  {[
    {attributes,[key,value]},
    {rocksdb_copies, [node()]}
   ],[],fun() ->
            mnesia:write({ledger_tree,<<"R">>,db_merkle_trees:empty()})
        end
  };
%mnesia:transaction(fun()-> mnesia:write({ledger_tree,<<"R">>,db_merkle_trees:empty()}) end)

table_descr(Any) ->
  throw({no_table_descr, Any}).

create_table(TN) ->
  {Descr, Indexes, Createfun} = table_descr(TN),
  {mnesia:create_table(TN, Descr),
   [ mnesia:add_table_index(TN, Idx) || Idx <- Indexes ],
   if is_function(Createfun) ->
        mnesia:transaction(fun() ->
                               Createfun()
                           end);
      true ->
        ignore
   end
  }.

start_db() ->
  _ = mnesia:create_schema([node()]),
  mnesia:start(),
  mnesia_rocksdb:register(),
  %mnesia:change_table_copy_type(schema, node(), disc_copies),
  ensure_tables(tables()).

bi_set_ver(#bal_items{address=Address, key=Key, path=Path}=BI,Ver) ->
  BI#bal_items{version=Ver,
               addr_ver={Address, Ver},
               addr_key={Address, Key},
               addr_key_ver_path={Address, Key, Ver, Path}
              }.

bi_create(Address,Ver,Key,Path,Introduced,Value) ->
  #bal_items{address=Address,
             version=Ver,
             key=Key,
             path=Path,
             introduced=Introduced,
             value=Value,
             addr_ver={Address, Ver},
             addr_key={Address, Key},
             addr_key_ver_path={Address, Key, Ver, Path}
            }.

put(_Address, Bal) ->
  Changes=maps:get(changes,Bal),
  lists:foldl(
    fun(_Field,Acc) ->
        Acc
    end, #{}, Changes).

get_vers(Address) -> 
  get_vers(Address,trans).

get_vers(Address, notrans) -> 
  {Addr,Key}=case Address of
               {A, K} when is_binary(A) ->
                 {A, K};
               A when is_binary(A) ->
                 {A, '_'}
             end,

  mnesia:match_object(bal_items,
                      #bal_items{
                         address=Addr,
                         version='_',
                         key=Key,
                         path='_',
                         introduced='_',
                         value='_',
                         addr_ver='_',
                         addr_key='_',
                         addr_key_ver_path='_'
                        },
                      read);

get_vers(Address, trans) -> 
  {atomic,List}=mnesia:transaction(
                  fun()->
                      get_vers(Address, notrans)
                  end),
  List.

get(Address) -> 
  get(Address,trans).

get(Address, notrans) -> 
  mnesia:match_object(bal_items,
                      #bal_items{
                         address=Address,
                         version=latest,
                         key='_',
                         path='_',
                         introduced='_',
                         value='_',
                         addr_ver='_',
                         addr_key='_',
                         addr_key_ver_path='_'
                        },
                      read);

get(Address, trans) -> 
  {atomic,List}=mnesia:transaction(
                  fun()->
                      get(Address, notrans)
                  end),
  List.

hashl(BIs) when is_list(BIs) ->
  MT=lists:foldl(
    fun(#bal_items{key=K,path=P,value=V},Acc) ->
        gb_merkle_trees:enter(sext:encode({K,P}),sext:encode(V),Acc)
    end, gb_merkle_trees:empty(), BIs),
  gb_merkle_trees:root_hash(MT).


hash(Address) when is_binary(Address) ->
  BIs=get(Address),
  PL=lists:map(
    fun(#bal_items{key=K,path=P,value=V}) ->
        {sext:encode({K,P}),sext:encode(V)}
    end, BIs),
  MT=gb_merkle_trees:from_list(PL),
  gb_merkle_trees:root_hash(MT).

bals2patch(Data) ->
  bals2patch(Data,[]).

bals2patch([], Acc) -> Acc; 
bals2patch([{A,Bal}|Rest], PRes) ->
  Res=maps:fold(
        fun (Key,Val,Acc) when Key == amount;
                               Key == code;
                               Key == pubkey;
                               Key == vm;
                               Key == view;
                               Key == t;
                               Key == seq;
                               Key == usk;
                               Key == lastblk ->
            [bi_create(A, latest, Key, [], here, Val)|Acc];
            (state,BState,Acc) ->
            case bal:get(vm,Bal) of
              <<"chainfee">> ->
                [bi_create(A, latest, state, <<>>, here, BState)|Acc];
              _ ->
                {ok, State} = msgpack:unpack(BState),
                maps:fold(
                  fun(K,V,Ac) ->
                      [bi_create(A, latest, state, K, here, V)|Ac]
                  end, Acc, State)
            end;
            (changes,_,Acc) -> Acc;
            (Key,_,Acc) ->
            io:format("Unhandled field ~p~n",[Key]),
            Acc
        end, PRes, Bal),
   bals2patch(Rest,Res).

dbmtfun(get, Key, Acc) ->
  [{ledger_tree, Key, Val}] = mnesia:read({ledger_tree,Key}),
  {Val,Acc};

dbmtfun(put, {Key, Value}, Acc) ->
  ok=mnesia:write({ledger_tree,Key,Value}),
  Acc;

dbmtfun(del, Key, Acc) ->
  ok=mnesia:delete({ledger_tree,Key}),
  Acc.


do_apply(Patches, Height) ->
  if is_integer(Height) ->
       lists:foreach(
         fun(#bal_items{addr_key_ver_path=AKVP,value=NewVal}=BalItem) ->
             case mnesia:read(bal_items, AKVP) of
               [] ->
                 io:format("Insert ~p~n",[AKVP]),
                 mnesia:write(BalItem#bal_items{introduced=Height});
               [#bal_items{introduced=OVer, value=OVal}=OldBal]  ->
                 if(OVal == NewVal) ->
                     io:format("Ignore ~p~n",[AKVP]),
                     ok;
                   true ->
                     io:format("Update ~p~n",[AKVP]),
                     OldBal1=bi_set_ver(OldBal,OVer),
                     io:format("Old ~p~n",[OldBal1]),
                     mnesia:write(OldBal1),
                     mnesia:write(BalItem#bal_items{introduced=Height})
                 end
             end
         end,
         Patches
        );
     true ->
       lists:foreach( fun mnesia:write/1, Patches)
  end,
  ChAddrs=lists:usort([ Address || #bal_items{address=Address} <- Patches ]),
  NewLedger=[ {Address, hashl(get(Address,notrans))} || Address <- ChAddrs ],
  io:format("NL ~p~n",[NewLedger]),
  lists:foldl(
    fun({Addr,Hash},Acc) ->
        db_merkle_trees:enter(Addr, Hash, {fun dbmtfun/3,Acc})
    end, #{}, NewLedger),
  db_merkle_trees:root_hash({fun dbmtfun/3,
                             db_merkle_trees:balance({fun dbmtfun/3,#{}})
                            }).

apply_patch(Patches, check) ->
  F=fun() ->
        throw({'abort',do_apply(Patches, undefined)})
    end,
  {aborted,{throw,{abort,NewHash}}}=mnesia:transaction(F),
  NewHash;

apply_patch(Patches, {commit, Height}) ->
  F=fun() ->
        do_apply(Patches, Height)
    end,
  {atomic,Res}=mnesia:transaction(F),
  Res.
