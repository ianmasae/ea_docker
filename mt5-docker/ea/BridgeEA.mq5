//+------------------------------------------------------------------+
//| BridgeEA.mq5 — TCP Socket Bridge for Python Trading API          |
//|                                                                    |
//| Connects to the Python FastAPI server via TCP socket.              |
//| Receives JSON commands, executes them, sends JSON responses.       |
//| Protocol: 4-byte big-endian length prefix + JSON payload.          |
//+------------------------------------------------------------------+
#property copyright "MT5 Docker Bridge"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input string InpHost       = "127.0.0.1";  // Bridge server host
input int    InpPort       = 15555;         // Bridge server port
input int    InpTimerMs    = 100;           // Poll interval (ms)
input int    InpReconnectS = 5;             // Reconnect delay (seconds)

//--- Globals
int    g_socket = INVALID_HANDLE;
bool   g_connected = false;
datetime g_lastConnectAttempt = 0;
CTrade g_trade;
uchar  g_recvBuf[];
int    g_recvBufLen = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(InpTimerMs);
   ArrayResize(g_recvBuf, 0);
   g_recvBufLen = 0;
   Print("BridgeEA: Initialized. Will connect to ", InpHost, ":", InpPort);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Disconnect();
   Print("BridgeEA: Deinitialized (reason=", reason, ")");
}

//+------------------------------------------------------------------+
//| Timer — main polling loop                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Try to connect if not connected
   if(!g_connected)
   {
      datetime now = TimeCurrent();
      if(now - g_lastConnectAttempt < InpReconnectS)
         return;
      g_lastConnectAttempt = now;
      Connect();
      if(!g_connected) return;
   }

   // Read and process any pending messages
   ReadAndProcess();
}

//+------------------------------------------------------------------+
//| Connect to the Python TCP server                                   |
//+------------------------------------------------------------------+
void Connect()
{
   g_socket = SocketCreate();
   if(g_socket == INVALID_HANDLE)
   {
      Print("BridgeEA: SocketCreate failed: ", GetLastError());
      return;
   }

   if(!SocketConnect(g_socket, InpHost, InpPort, 3000))
   {
      int err = GetLastError();
      if(err != 4014) // Suppress frequent "connect failed" noise
         Print("BridgeEA: Connect failed to ", InpHost, ":", InpPort, " error=", err);
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
      return;
   }

   g_connected = true;
   ArrayResize(g_recvBuf, 0);
   g_recvBufLen = 0;
   Print("BridgeEA: Connected to ", InpHost, ":", InpPort);
}

//+------------------------------------------------------------------+
//| Disconnect from server                                             |
//+------------------------------------------------------------------+
void Disconnect()
{
   if(g_socket != INVALID_HANDLE)
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
   }
   g_connected = false;
}

//+------------------------------------------------------------------+
//| Read data from socket and process complete messages                |
//+------------------------------------------------------------------+
void ReadAndProcess()
{
   if(g_socket == INVALID_HANDLE) return;

   // Read available data
   uint avail = SocketIsReadable(g_socket);
   if(avail == 0) return;

   uchar buf[];
   int read = SocketRead(g_socket, buf, (int)avail, 100);
   if(read <= 0)
   {
      Print("BridgeEA: Socket read error, disconnecting");
      Disconnect();
      return;
   }

   // Append to receive buffer
   int oldLen = g_recvBufLen;
   g_recvBufLen += read;
   ArrayResize(g_recvBuf, g_recvBufLen);
   ArrayCopy(g_recvBuf, buf, oldLen, 0, read);

   // Process complete messages (may have multiple)
   while(g_recvBufLen >= 4)
   {
      // Read 4-byte big-endian length
      uint msgLen = ((uint)g_recvBuf[0] << 24) |
                    ((uint)g_recvBuf[1] << 16) |
                    ((uint)g_recvBuf[2] << 8)  |
                    ((uint)g_recvBuf[3]);

      if(msgLen > 1000000) // Sanity check
      {
         Print("BridgeEA: Invalid message length: ", msgLen);
         Disconnect();
         return;
      }

      if(g_recvBufLen < (int)(4 + msgLen))
         break; // Wait for more data

      // Extract message
      uchar msgBuf[];
      ArrayResize(msgBuf, (int)msgLen);
      ArrayCopy(msgBuf, g_recvBuf, 0, 4, (int)msgLen);
      string jsonStr = CharArrayToString(msgBuf, 0, (int)msgLen, CP_UTF8);

      // Remove processed bytes from buffer
      int remaining = g_recvBufLen - 4 - (int)msgLen;
      if(remaining > 0)
      {
         uchar tmp[];
         ArrayResize(tmp, remaining);
         ArrayCopy(tmp, g_recvBuf, 0, 4 + (int)msgLen, remaining);
         ArrayResize(g_recvBuf, remaining);
         ArrayCopy(g_recvBuf, tmp, 0, 0, remaining);
      }
      else
      {
         ArrayResize(g_recvBuf, 0);
      }
      g_recvBufLen = remaining;

      // Process the message
      ProcessMessage(jsonStr);
   }
}

//+------------------------------------------------------------------+
//| Send a length-prefixed JSON response                               |
//+------------------------------------------------------------------+
bool SendResponse(string json)
{
   if(g_socket == INVALID_HANDLE) return false;

   uchar payload[];
   int payloadLen = StringToCharArray(json, payload, 0, -1, CP_UTF8) - 1; // -1 for null terminator
   if(payloadLen <= 0) return false;

   // Build 4-byte big-endian header
   uchar header[4];
   header[0] = (uchar)((payloadLen >> 24) & 0xFF);
   header[1] = (uchar)((payloadLen >> 16) & 0xFF);
   header[2] = (uchar)((payloadLen >> 8) & 0xFF);
   header[3] = (uchar)(payloadLen & 0xFF);

   // Send header + payload
   uchar packet[];
   ArrayResize(packet, 4 + payloadLen);
   ArrayCopy(packet, header, 0, 0, 4);
   ArrayCopy(packet, payload, 4, 0, payloadLen);

   int sent = SocketSend(g_socket, packet, 4 + payloadLen);
   if(sent != 4 + payloadLen)
   {
      Print("BridgeEA: Send failed (sent=", sent, " expected=", 4 + payloadLen, ")");
      Disconnect();
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Simple JSON string value extraction                                |
//+------------------------------------------------------------------+
string JsonGetString(const string &json, const string &key)
{
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";

   // Find the colon after the key
   int colonPos = StringFind(json, ":", pos + StringLen(search));
   if(colonPos < 0) return "";

   // Find the opening quote of the value
   int quoteStart = StringFind(json, "\"", colonPos + 1);
   if(quoteStart < 0) return "";

   // Find the closing quote (handle escaped quotes)
   int quoteEnd = quoteStart + 1;
   while(quoteEnd < StringLen(json))
   {
      int nextQuote = StringFind(json, "\"", quoteEnd);
      if(nextQuote < 0) break;
      // Check if escaped
      if(nextQuote > 0 && StringGetCharacter(json, nextQuote - 1) == '\\')
      {
         quoteEnd = nextQuote + 1;
         continue;
      }
      quoteEnd = nextQuote;
      break;
   }

   return StringSubstr(json, quoteStart + 1, quoteEnd - quoteStart - 1);
}

//+------------------------------------------------------------------+
//| Simple JSON number value extraction                                |
//+------------------------------------------------------------------+
double JsonGetDouble(const string &json, const string &key)
{
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return 0.0;

   int colonPos = StringFind(json, ":", pos + StringLen(search));
   if(colonPos < 0) return 0.0;

   // Skip whitespace
   int start = colonPos + 1;
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   // Read number
   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '+' || ch == 'e' || ch == 'E')
         end++;
      else
         break;
   }

   return StringToDouble(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| Simple JSON integer value extraction                               |
//+------------------------------------------------------------------+
long JsonGetLong(const string &json, const string &key)
{
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return 0;

   int colonPos = StringFind(json, ":", pos + StringLen(search));
   if(colonPos < 0) return 0;

   int start = colonPos + 1;
   while(start < StringLen(json) && StringGetCharacter(json, start) == ' ')
      start++;

   int end = start;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '-')
         end++;
      else
         break;
   }

   return StringToInteger(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| Extract nested "params" JSON object as string                      |
//+------------------------------------------------------------------+
string JsonGetParams(const string &json)
{
   int pos = StringFind(json, "\"params\"");
   if(pos < 0) return "{}";

   int colonPos = StringFind(json, ":", pos + 8);
   if(colonPos < 0) return "{}";

   // Find opening brace
   int braceStart = StringFind(json, "{", colonPos + 1);
   if(braceStart < 0) return "{}";

   // Find matching closing brace
   int depth = 1;
   int i = braceStart + 1;
   while(i < StringLen(json) && depth > 0)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch == '{') depth++;
      else if(ch == '}') depth--;
      i++;
   }

   return StringSubstr(json, braceStart, i - braceStart);
}

//+------------------------------------------------------------------+
//| Escape a string for JSON output                                    |
//+------------------------------------------------------------------+
string EscapeJson(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
}

//+------------------------------------------------------------------+
//| Process a single JSON command message                              |
//+------------------------------------------------------------------+
void ProcessMessage(const string &jsonStr)
{
   string reqId = JsonGetString(jsonStr, "id");
   string command = JsonGetString(jsonStr, "command");
   string params = JsonGetParams(jsonStr);

   if(command == "")
   {
      SendResponse("{\"id\":\"" + reqId + "\",\"error\":\"missing command\"}");
      return;
   }

   string response = "";

   if(command == "ping")
      response = HandlePing(reqId);
   else if(command == "account_info")
      response = HandleAccountInfo(reqId);
   else if(command == "positions")
      response = HandlePositions(reqId);
   else if(command == "orders")
      response = HandleOrders(reqId);
   else if(command == "history")
      response = HandleHistory(reqId, params);
   else if(command == "market_buy")
      response = HandleMarketBuy(reqId, params);
   else if(command == "market_sell")
      response = HandleMarketSell(reqId, params);
   else if(command == "close_position")
      response = HandleClosePosition(reqId, params);
   else if(command == "modify_position")
      response = HandleModifyPosition(reqId, params);
   else if(command == "symbol_info")
      response = HandleSymbolInfo(reqId, params);
   else if(command == "symbols_list")
      response = HandleSymbolsList(reqId);
   else if(command == "tick")
      response = HandleTick(reqId, params);
   else
      response = "{\"id\":\"" + reqId + "\",\"error\":\"unknown command: " + EscapeJson(command) + "\"}";

   if(response != "")
      SendResponse(response);
}

//+------------------------------------------------------------------+
//| Command Handlers                                                   |
//+------------------------------------------------------------------+

string HandlePing(const string &reqId)
{
   return "{\"id\":\"" + reqId + "\",\"data\":{\"pong\":true,\"time\":" +
          IntegerToString((long)TimeCurrent()) + "}}";
}

string HandleAccountInfo(const string &reqId)
{
   return "{\"id\":\"" + reqId + "\",\"data\":{"
      "\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ","
      "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ","
      "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ","
      "\"margin\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + ","
      "\"free_margin\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + ","
      "\"leverage\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)) + ","
      "\"currency\":\"" + EscapeJson(AccountInfoString(ACCOUNT_CURRENCY)) + "\","
      "\"server\":\"" + EscapeJson(AccountInfoString(ACCOUNT_SERVER)) + "\","
      "\"name\":\"" + EscapeJson(AccountInfoString(ACCOUNT_NAME)) + "\","
      "\"company\":\"" + EscapeJson(AccountInfoString(ACCOUNT_COMPANY)) + "\","
      "\"trade_allowed\":" + (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "true" : "false") +
      "}}";
}

string HandlePositions(const string &reqId)
{
   string items = "";
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(items != "") items += ",";
      items += "{"
         "\"ticket\":" + IntegerToString((long)ticket) + ","
         "\"symbol\":\"" + EscapeJson(PositionGetString(POSITION_SYMBOL)) + "\","
         "\"type\":" + IntegerToString((long)PositionGetInteger(POSITION_TYPE)) + ","
         "\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 8) + ","
         "\"price_open\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + ","
         "\"price_current\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), 8) + ","
         "\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), 8) + ","
         "\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), 8) + ","
         "\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + ","
         "\"swap\":" + DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + ","
         "\"commission\":" + DoubleToString(PositionGetDouble(POSITION_COMMISSION), 2) + ","
         "\"time\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME)) + ","
         "\"magic\":" + IntegerToString((long)PositionGetInteger(POSITION_MAGIC)) + ","
         "\"comment\":\"" + EscapeJson(PositionGetString(POSITION_COMMENT)) + "\""
         "}";
   }

   return "{\"id\":\"" + reqId + "\",\"data\":[" + items + "]}";
}

string HandleOrders(const string &reqId)
{
   string items = "";
   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if(items != "") items += ",";
      items += "{"
         "\"ticket\":" + IntegerToString((long)ticket) + ","
         "\"symbol\":\"" + EscapeJson(OrderGetString(ORDER_SYMBOL)) + "\","
         "\"type\":" + IntegerToString((long)OrderGetInteger(ORDER_TYPE)) + ","
         "\"volume_initial\":" + DoubleToString(OrderGetDouble(ORDER_VOLUME_INITIAL), 8) + ","
         "\"volume_current\":" + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 8) + ","
         "\"price_open\":" + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), 8) + ","
         "\"sl\":" + DoubleToString(OrderGetDouble(ORDER_SL), 8) + ","
         "\"tp\":" + DoubleToString(OrderGetDouble(ORDER_TP), 8) + ","
         "\"time_setup\":" + IntegerToString((long)OrderGetInteger(ORDER_TIME_SETUP)) + ","
         "\"time_done\":" + IntegerToString((long)OrderGetInteger(ORDER_TIME_DONE)) + ","
         "\"state\":" + IntegerToString((long)OrderGetInteger(ORDER_STATE)) + ","
         "\"magic\":" + IntegerToString((long)OrderGetInteger(ORDER_MAGIC)) + ","
         "\"comment\":\"" + EscapeJson(OrderGetString(ORDER_COMMENT)) + "\""
         "}";
   }

   return "{\"id\":\"" + reqId + "\",\"data\":[" + items + "]}";
}

string HandleHistory(const string &reqId, const string &params)
{
   long fromTs = JsonGetLong(params, "from_ts");
   long toTs = JsonGetLong(params, "to_ts");

   // Default: last 24 hours
   datetime now = TimeCurrent();
   datetime from = (fromTs > 0) ? (datetime)fromTs : now - 86400;
   datetime to   = (toTs > 0)   ? (datetime)toTs   : now;

   if(!HistorySelect(from, to))
      return "{\"id\":\"" + reqId + "\",\"error\":\"HistorySelect failed\"}";

   string items = "";
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      if(items != "") items += ",";
      items += "{"
         "\"ticket\":" + IntegerToString((long)ticket) + ","
         "\"order\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_ORDER)) + ","
         "\"symbol\":\"" + EscapeJson(HistoryDealGetString(ticket, DEAL_SYMBOL)) + "\","
         "\"type\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_TYPE)) + ","
         "\"direction\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_ENTRY)) + ","
         "\"volume\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 8) + ","
         "\"price\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), 8) + ","
         "\"commission\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_COMMISSION), 2) + ","
         "\"swap\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_SWAP), 2) + ","
         "\"profit\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PROFIT), 2) + ","
         "\"time\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_TIME)) + ","
         "\"magic\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_MAGIC)) + ","
         "\"comment\":\"" + EscapeJson(HistoryDealGetString(ticket, DEAL_COMMENT)) + "\""
         "}";
   }

   return "{\"id\":\"" + reqId + "\",\"data\":[" + items + "]}";
}

string HandleMarketBuy(const string &reqId, const string &params)
{
   string symbol = JsonGetString(params, "symbol");
   double volume = JsonGetDouble(params, "volume");
   double sl = JsonGetDouble(params, "sl");
   double tp = JsonGetDouble(params, "tp");
   string comment = JsonGetString(params, "comment");

   if(symbol == "" || volume <= 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"invalid symbol or volume\"}";

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(ask == 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"symbol not found or no price: " + EscapeJson(symbol) + "\"}";

   g_trade.SetExpertMagicNumber(0);
   bool ok = g_trade.Buy(volume, symbol, ask, sl, tp, comment);

   return BuildTradeResult(reqId, ok);
}

string HandleMarketSell(const string &reqId, const string &params)
{
   string symbol = JsonGetString(params, "symbol");
   double volume = JsonGetDouble(params, "volume");
   double sl = JsonGetDouble(params, "sl");
   double tp = JsonGetDouble(params, "tp");
   string comment = JsonGetString(params, "comment");

   if(symbol == "" || volume <= 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"invalid symbol or volume\"}";

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(bid == 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"symbol not found or no price: " + EscapeJson(symbol) + "\"}";

   g_trade.SetExpertMagicNumber(0);
   bool ok = g_trade.Sell(volume, symbol, bid, sl, tp, comment);

   return BuildTradeResult(reqId, ok);
}

string HandleClosePosition(const string &reqId, const string &params)
{
   long ticket = JsonGetLong(params, "ticket");
   if(ticket <= 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"invalid ticket\"}";

   bool ok = g_trade.PositionClose((ulong)ticket);
   return BuildTradeResult(reqId, ok);
}

string HandleModifyPosition(const string &reqId, const string &params)
{
   long ticket = JsonGetLong(params, "ticket");
   double sl = JsonGetDouble(params, "sl");
   double tp = JsonGetDouble(params, "tp");

   if(ticket <= 0)
      return "{\"id\":\"" + reqId + "\",\"error\":\"invalid ticket\"}";

   bool ok = g_trade.PositionModify((ulong)ticket, sl, tp);
   return BuildTradeResult(reqId, ok);
}

string HandleSymbolInfo(const string &reqId, const string &params)
{
   string symbol = JsonGetString(params, "symbol");
   if(symbol == "")
      return "{\"id\":\"" + reqId + "\",\"error\":\"missing symbol\"}";

   if(!SymbolSelect(symbol, true))
      return "{\"id\":\"" + reqId + "\",\"error\":\"symbol not found: " + EscapeJson(symbol) + "\"}";

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   return "{\"id\":\"" + reqId + "\",\"data\":{"
      "\"name\":\"" + EscapeJson(symbol) + "\","
      "\"bid\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_BID), digits) + ","
      "\"ask\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_ASK), digits) + ","
      "\"spread\":" + IntegerToString(SymbolInfoInteger(symbol, SYMBOL_SPREAD)) + ","
      "\"digits\":" + IntegerToString(digits) + ","
      "\"volume_min\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), 8) + ","
      "\"volume_max\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), 8) + ","
      "\"volume_step\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP), 8) + ","
      "\"trade_mode\":" + IntegerToString(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)) + ","
      "\"point\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_POINT), 8) + ","
      "\"tick_size\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE), 8) + ","
      "\"tick_value\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE), 4) + ","
      "\"swap_long\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_SWAP_LONG), 4) + ","
      "\"swap_short\":" + DoubleToString(SymbolInfoDouble(symbol, SYMBOL_SWAP_SHORT), 4) +
      "}}";
}

string HandleSymbolsList(const string &reqId)
{
   string items = "";
   int total = SymbolsTotal(true); // Only visible symbols

   for(int i = 0; i < total; i++)
   {
      string name = SymbolName(i, true);
      if(name == "") continue;
      if(items != "") items += ",";
      items += "\"" + EscapeJson(name) + "\"";
   }

   return "{\"id\":\"" + reqId + "\",\"data\":[" + items + "]}";
}

string HandleTick(const string &reqId, const string &params)
{
   string symbol = JsonGetString(params, "symbol");
   if(symbol == "")
      return "{\"id\":\"" + reqId + "\",\"error\":\"missing symbol\"}";

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return "{\"id\":\"" + reqId + "\",\"error\":\"tick not available for: " + EscapeJson(symbol) + "\"}";

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   return "{\"id\":\"" + reqId + "\",\"data\":{"
      "\"symbol\":\"" + EscapeJson(symbol) + "\","
      "\"bid\":" + DoubleToString(tick.bid, digits) + ","
      "\"ask\":" + DoubleToString(tick.ask, digits) + ","
      "\"last\":" + DoubleToString(tick.last, digits) + ","
      "\"volume\":" + DoubleToString((double)tick.volume, 2) + ","
      "\"time\":" + IntegerToString((long)tick.time) +
      "}}";
}

//+------------------------------------------------------------------+
//| Build trade result JSON from CTrade state                          |
//+------------------------------------------------------------------+
string BuildTradeResult(const string &reqId, bool ok)
{
   MqlTradeResult result;
   g_trade.Result(result);

   return "{\"id\":\"" + reqId + "\",\"data\":{"
      "\"success\":" + (ok ? "true" : "false") + ","
      "\"retcode\":" + IntegerToString(result.retcode) + ","
      "\"order\":" + IntegerToString((long)result.order) + ","
      "\"deal\":" + IntegerToString((long)result.deal) + ","
      "\"volume\":" + DoubleToString(result.volume, 8) + ","
      "\"price\":" + DoubleToString(result.price, 8) + ","
      "\"comment\":\"" + EscapeJson(result.comment) + "\""
      "}}";
}

//+------------------------------------------------------------------+
//| OnTick — not used but required                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Bridge uses timer-based polling, not tick events
}
//+------------------------------------------------------------------+
