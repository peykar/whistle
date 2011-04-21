%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, James Aimonetti
%%% @doc
%%% Simple cache server
%%% @end
%%% Created : 30 Mar 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(wh_cache).

-behaviour(gen_server).

%% API
-export([start_link/0, store/2, store/3, fetch/1, erase/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 
-define(EXPIRES, 3600). %% an hour

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% T - seconds to store the pair
-spec(store/2 :: (K :: term(), V :: term()) -> no_return()).
-spec(store/3 :: (K :: term(), V :: term(), T :: integer()) -> no_return()).
store(K, V) ->
    store(K, V, ?EXPIRES).
store(K, V, T) ->
    gen_server:cast(?SERVER, {store, K, V, T}).

-spec(fetch/1 :: (K :: term()) -> tuple(ok, term()) | tuple(error, not_found)).
fetch(K) ->
    gen_server:call(?SERVER, {fetch, K}).

-spec(erase/1 :: (K :: term()) -> no_return()).
erase(K) ->
    gen_server:cast(?SERVER, {erase, K}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, _} = timer:send_interval(1000, flush),
    {ok, dict:new()}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({fetch, K}, _, Dict) ->
    case dict:find(K, Dict) of
	{ok, {_, V, T}} -> {reply, {ok, V}, dict:update(K, fun(_) -> {whistle_util:current_tstamp()+T, V, T} end, Dict)};
	error -> {reply, {error, not_found}, Dict}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({store, K, V, T}, Dict) ->
    {noreply, dict:store(K, {whistle_util:current_tstamp()+T, V, T}, Dict)};
handle_cast({erase, K}, Dict) ->
    {noreply, dict:erase(K, Dict)}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(flush, Dict) ->
    Now = whistle_util:current_tstamp(),
    {noreply, dict:filter(fun(_, {T, _, _}) -> Now < T end, Dict)};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================