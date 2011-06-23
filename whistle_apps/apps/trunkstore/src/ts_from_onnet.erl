%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 20 Jun 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ts_from_onnet).

-export([start_link/1, init/2]).

-include("ts.hrl").

-record(state, {
	  aleg_callid = <<>> :: binary()
	  ,bleg_callid = <<>> :: binary()
          ,acctid = <<>> :: binary()
	  ,route_req_jobj = ?EMPTY_JSON_OBJECT :: json_object()
          ,onnet = ?EMPTY_JSON_OBJECT :: json_object()
          ,my_q = <<>> :: binary()
          ,callctl_q = <<>> :: binary()
          ,failover = ?EMPTY_JSON_OBJECT :: json_object()
	 }).

-define(APP_NAME, <<"ts_from_onnet">>).
-define(APP_VERSION, <<"0.0.5">>).
-define(WAIT_FOR_WIN_TIMEOUT, 5000).
-define(WAIT_FOR_OFFNET_RESPONSE_TIMEOUT, 60000).
-define(WAIT_FOR_BRIDGE_TIMEOUT, 10000).
-define(WAIT_FOR_HANGUP_TIMEOUT, 1000 * 60 * 60 * 2). %% 2 hours
-define(WAIT_FOR_CDR_TIMEOUT, 5000).

start_link(RouteReqJObj) ->
    proc_lib:start_link(?MODULE, init, [self(), RouteReqJObj]).

init(Parent, RouteReqJObj) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    CallID = wh_json:get_value(<<"Call-ID">>, RouteReqJObj),
    put(callid, CallID),
    start_amqp(#state{aleg_callid=CallID, route_req_jobj=RouteReqJObj}).

start_amqp(#state{route_req_jobj=JObj}=State) ->
    Q = amqp_util:new_queue(),

    %% Bind the queue to an exchange
    _ = amqp_util:bind_q_to_targeted(Q),
    amqp_util:basic_consume(Q, [{exclusive, false}]),

    onnet_data(State#state{my_q=Q}, JObj).

onnet_data(#state{aleg_callid=CallID, my_q=Q}=State, JObj) ->
    ChannelVars = wh_json:get_value(<<"Custom-Channel-Vars">>, JObj, ?EMPTY_JSON_OBJECT),
    AcctID = wh_json:get_value(<<"Account-ID">>, ChannelVars),

    [ToUser, _ToDomain] = binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>),
    ToDID = whistle_util:to_e164(ToUser),

    FromUser = wh_json:get_value(<<"Caller-ID-Name">>, JObj),
    DIDJObj = case ts_util:lookup_did(FromUser) of
		  {ok, DIDFlags} -> DIDFlags;
		  _ -> ?EMPTY_JSON_OBJECT
	      end,

    RouteOptions = wh_json:get_value(<<"options">>, DIDJObj, []),

    {ok, RateData} = ts_credit:reserve(ToDID, CallID, AcctID, outbound, RouteOptions),

    Command = [
	       {<<"Call-ID">>, CallID}
	       ,{<<"Resource-Type">>, <<"audio">>}
	       ,{<<"To-DID">>, ToDID}
	       ,{<<"Account-ID">>, AcctID}
	       ,{<<"Application-Name">>, <<"bridge">>}
	       ,{<<"Flags">>, RouteOptions}
	       ,{<<"Timeout">>, wh_json:get_value(<<"timeout">>, DIDJObj)}
	       ,{<<"Ignore-Early-Media">>, wh_json:get_value(<<"ignore_early_media">>, DIDJObj)}
	       %% ,{<<"Outgoing-Caller-ID-Name">>, CallerIDName}
	       %% ,{<<"Outgoing-Caller-ID-Number">>, CallerIDNum}
	       ,{<<"Ringback">>, wh_json:get_value(<<"ringback">>, DIDJObj)}
	       ,{<<"Custom-Channel-Vars">>, {struct, RateData}}
	       | whistle_api:default_headers(Q, <<"resource">>, <<"offnet_req">>, ?APP_NAME, ?APP_VERSION)
	      ],
    send_park(State#state{acctid=AcctID}, Command).

send_park(#state{route_req_jobj=JObj, my_q=Q}=State, Command) ->
    JObj1 = {struct, [ {<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
                       ,{<<"Routes">>, []}
                       ,{<<"Method">>, <<"park">>}
		       | whistle_api:default_headers(Q, <<"dialplan">>, <<"route_resp">>, ?APP_NAME, ?APP_VERSION) ]
	    },
    RespQ = wh_json:get_value(<<"Server-ID">>, JObj),
    JSON = whistle_api:route_resp(JObj1),
    ?LOG("Sending to ~s: ~s", [RespQ, JSON]),
    amqp_util:targeted_publish(RespQ, JSON, <<"application/json">>),

    wait_for_win(State, Command, ?WAIT_FOR_WIN_TIMEOUT).

wait_for_win(#state{aleg_callid=CallID, my_q=Q}=State, Command, Timeout) ->
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    WinJObj = mochijson2:decode(Payload),
	    true = whistle_api:route_win_v(WinJObj),
	    CallID = wh_json:get_value(<<"Call-ID">>, WinJObj),

	    _ = amqp_util:bind_q_to_callevt(Q, CallID),
	    _ = amqp_util:bind_q_to_callevt(Q, CallID, cdr),

	    CallctlQ = wh_json:get_value(<<"Control-Queue">>, WinJObj),

	    send_offnet(State#state{callctl_q=CallctlQ}, [{<<"Control-Queue">>, CallctlQ} | Command])
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for route_win", [Timeout]),
	    _ = amqp_util:bind_q_to_callevt(Q, CallID),
	    _ = amqp_util:bind_q_to_callevt(Q, CallID, cdr),
	    wait_for_bridge(State, ?WAIT_FOR_BRIDGE_TIMEOUT)
    end.

send_offnet(State, Command) ->
    {ok, Payload} = whistle_api:offnet_resource_req([ KV || {_, V}=KV <- Command, V =/= undefined ]),
    ?LOG("Sending offnet: ~s", [Payload]),
    amqp_util:offnet_resource_publish(Payload),
    wait_for_offnet_bridge(State, ?WAIT_FOR_OFFNET_RESPONSE_TIMEOUT).

wait_for_offnet_bridge(#state{aleg_callid=CallID, acctid=AcctID, my_q=Q}=State, Timeout) ->
    Start = erlang:now(),
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
	    case { wh_json:get_value(<<"Event-Name">>, JObj), wh_json:get_value(<<"Event-Category">>, JObj) } of
                { <<"offnet_resp">>, <<"resource">> } ->
		    BLegCallID = wh_json:get_value(<<"Call-ID">>, JObj),
		    amqp_util:bind_q_to_callevt(Q, BLegCallID, cdr),
		    wait_for_cdr(State#state{bleg_callid=BLegCallID}, ?WAIT_FOR_HANGUP_TIMEOUT);
                { <<"resource_error">>, <<"resource">> } ->
		    ?LOG("Failed to failover to e164"),
		    ?LOG("Failure message: ~s", [wh_json:get_value(<<"Failure-Message">>, JObj)]),
		    ?LOG("Failure code: ~s", [wh_json:get_value(<<"Failure-Code">>, JObj)]),

		    %% TODO: Send Commands to CtlQ to play media depending on failure code

		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                { <<"CHANNEL_HANGUP">>, <<"call_event">> } ->
		    ?LOG("Hangup received"),
		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                { _, <<"error">> } ->
		    ?LOG("Error received"),
		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                _ ->
		    Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
                    wait_for_offnet_bridge(State, Diff)
            end;
        _ ->
            Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
            wait_for_offnet_bridge(State, Diff)
    after Timeout ->
	    ?LOG("Offnet bridge timed out(~b)", [Timeout]),
	    ts_acctmgr:release_trunk(AcctID, CallID, 0)
    end.

wait_for_cdr(#state{aleg_callid=ALeg, bleg_callid=BLeg, acctid=AcctID}=State, Timeout) ->
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
            case { wh_json:get_value(<<"Event-Category">>, JObj)
		   ,wh_json:get_value(<<"Event-Name">>, JObj) } of
                { <<"call_event">>, <<"CHANNEL_HANGUP">> } ->
		    ?LOG("Hangup received, waiting on CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                { <<"error">>, _ } ->
		    ?LOG("Received error in event stream, waiting for CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
		{ <<"cdr">>, <<"call_detail">> } ->
		    true = whistle_api:call_cdr_v(JObj),

		    Leg = wh_json:get_value(<<"Call-ID">>, JObj),
		    Duration = ts_util:get_call_duration(JObj),

		    {R, RI, RM, S} = ts_util:get_rate_factors(JObj),
		    Cost = ts_util:calculate_cost(R, RI, RM, S, Duration),

		    ?LOG("CDR received for leg ~s", [Leg]),
		    ?LOG("Leg to be billed for ~b seconds", [Duration]),
		    ?LOG("Acct ~s to be charged ~p if per_min", [AcctID, Cost]),

		    case Leg =:= BLeg of
			true -> ts_acctmgr:release_trunk(AcctID, Leg, Cost);
			false -> ts_acctmgr:release_trunk(AcctID, ALeg, Cost)
		    end,

		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                _ ->
                    wait_for_cdr(State, ?WAIT_FOR_HANGUP_TIMEOUT)
            end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for CDR"),
	    %% will fail if already released
	    ts_acctmgr:release_trunk(AcctID, ALeg, 0)
    end.    

wait_for_bridge(#state{aleg_callid=ALeg, acctid=AcctID, my_q=Q}=State, Timeout) ->
    Start = erlang:now(),
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
	    true = whistle_api:call_event_v(JObj),

	    case { wh_json:get_value(<<"Application-Name">>, JObj)
		   ,wh_json:get_value(<<"Event-Name">>, JObj)
		   ,wh_json:get_value(<<"Event-Category">>, JObj) } of
		{ _, <<"CHANNEL_BRIDGE">>, <<"call_event">> } ->
		    BLeg = wh_json:get_value(<<"Other-Leg-Call-Id">>, JObj),
		    _ = amqp_util:bind_q_to_callevt(Q, BLeg, cdr),
		    ?LOG("Bridge to ~s successful", [BLeg]),
		    wait_for_cdr(State#state{bleg_callid=BLeg}, ?WAIT_FOR_HANGUP_TIMEOUT);
		{ <<"bridge">>, <<"CHANNEL_EXECUTE_COMPLETE">>, <<"call_event">> } ->
		    case wh_json:get_value(<<"Application-Response">>, JObj) of
			<<"SUCCESS">> ->
			    BLeg = wh_json:get_value(<<"Other-Leg-Call-Id">>, JObj),
			    _ = amqp_util:bind_q_to_callevt(Q, BLeg, cdr),
			    ?LOG("Bridge to ~s successful", [BLeg]),
			    wait_for_cdr(State#state{bleg_callid=BLeg}, ?WAIT_FOR_HANGUP_TIMEOUT);
			Cause ->
			    ?LOG("Failed to bridge: ~s", [Cause]),
			    ts_acctmgr:release_trunk(AcctID, ALeg, 0)
		    end;
		{ _, <<"CHANNEL_HANGUP">>, <<"call_event">> } ->
		    ts_acctmgr:release_trunk(AcctID, ALeg, 0),
		    ?LOG("Channel hungup");
		{ _, _, <<"error">> } ->
		    ts_acctmgr:release_trunk(AcctID, ALeg, 0),
		    ?LOG("Execution failed");
		_Other ->
		    ?LOG("Received other: ~p~n", [_Other]),
		    Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
		    ?LOG("~b left to timeout", [Diff]),
		    wait_for_bridge(State, Diff)
	    end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for bridge success", [Timeout])
    end.