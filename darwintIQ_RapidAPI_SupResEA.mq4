//+----------------------------------------------------------------------------------+
//|                    darwintIQ_SupResEA.mq4                                        |
//|   Fetches "latest" SupRes snapshot from RapidAPI and renders                     |
//|   S/R levels (weighted), regression channel, and swing structure                 |
//|                                                                                  |
//|  See more: https://rapidapi.com/darwintiq-darwintiq-default/api/darwintiq-supres |
//+----------------------------------------------------------------------------------+
#property strict

/* ============================ Inputs ============================ */
// RapidAPI endpoint
input string InpRapidAPIHost   = "darwintiq-supres.p.rapidapi.com";
input string InpRapidAPIKey    = "YOUR_RAPIDAPI_KEY";
input string InpApiPath        = "/api/rapidapi/supres/v1"; // your Next.js route
input string InpSymbolOverride = "";  // empty = use chart symbol

// Scheduling
input bool   InpFetchOnNewBar  = true;
input int    InpMinFetchSecs   = 60;     // minimum seconds between fetches
input int    InpTimeoutMs      = 8000;

// Multi-chart drawing
input bool   InpApplyToAllCharts = false;

// S/R visual
input bool   InpShowSR         = true;
input int    InpSRMaxLevels    = 24;     // safety cap
input color  InpSRColorLight   = clrPowderBlue; // touches=2
input color  InpSRColorHeavy   = clrDodgerBlue; // touches=3
input int    InpSRWidthLight   = 2;
input int    InpSRWidthHeavy   = 3;
input ENUM_LINE_STYLE InpSRStyle = STYLE_SOLID;

// Regression channel
input bool   InpShowRegression = true;
input color  InpRegMidColor    = clrBlue;
input color  InpRegUpColor     = clrSteelBlue;
input color  InpRegDnColor     = clrSteelBlue;
input int    InpRegWidth       = 2;

// Swing structure
input bool   InpShowSwing      = true;
input color  InpSwingTopColor  = clrDarkOrange;
input color  InpSwingBotColor  = clrSeaGreen;
input int    InpSwingWidth     = 2;

/* ============================ Globals =========================== */
string   g_ns           = "dIQ_SR"; // object name prefix
datetime g_lastBarTime  = 0;
datetime g_lastFetchAt  = 0;

string g_lastSymbol = "";
string g_lastOpenTime = "";

// Parsed payload (latest fetch)
struct SRLevel {
   string kind;   // "S" or "R"
   double price;
   int    touches; // 2 or 3 (or other)
};
SRLevel  g_levels[]; // dynamic

bool     g_hasReg=false;
datetime g_reg_t1=0; double g_reg_y1_mid=0, g_reg_y1_up=0, g_reg_y1_dn=0;
datetime g_reg_t2=0; double g_reg_y2_mid=0, g_reg_y2_up=0, g_reg_y2_dn=0;

bool     g_hasSwing=false;
datetime g_sw_top_t1=0; double g_sw_top_y1=0; datetime g_sw_top_t2=0; double g_sw_top_y2=0;
datetime g_sw_bot_t1=0; double g_sw_bot_y1=0; datetime g_sw_bot_t2=0; double g_sw_bot_y2=0;

/* ========================== Small Utils ========================= */
string Trim(const string s){
   string t=s;
   // left trim
   int i=0; while(i<StringLen(t)){
      int c=StringGetChar(t,i);
      if(c==' '||c=='\t'||c=='\r'||c=='\n') i++; else break;
   }
   if(i>0) t=StringSubstr(t,i);
   // right trim
   while(StringLen(t)>0){
      int c2=StringGetChar(t,StringLen(t)-1);
      if(c2==' '||c2=='\t'||c2=='\r'||c2=='\n') t=StringSubstr(t,0,StringLen(t)-1);
      else break;
   }
   return t;
}

string ToStr(int v){ return IntegerToString(v); }
string ToStrD(double v,int digits=5){ return DoubleToString(v,digits); }

// Convert "YYYY-MM-DD HH:MM:SS" -> datetime via StrToTime (expects '.' between Y-M-D)
datetime ParseIsoTime(const string iso){
   string s=iso;
   StringReplace(s,"-",".");
   return StrToTime(s); // MT4 can parse "YYYY.MM.DD HH:MM:SS"
}

/* =============== Minimal JSON helpers (string-find) ============== */
bool JsonGetStringLocal(const string json,int from,const string key,string &outVal){
   string needle="\""+key+"\"";
   int pos=StringFind(json,needle,from); if(pos<0) return false;
   int colon=StringFind(json,":",pos); if(colon<0) return false;
   // find first quote after colon
   int q1=StringFind(json,"\"",colon+1); if(q1<0) return false;
   int q2=StringFind(json,"\"",q1+1); if(q2<0) return false;
   outVal=StringSubstr(json,q1+1,q2-(q1+1));
   return true;
}
bool JsonGetNumberLocal(const string json,int from,const string key,double &outNum){
   string needle="\""+key+"\"";
   int pos=StringFind(json,needle,from); if(pos<0) return false;
   int colon=StringFind(json,":",pos); if(colon<0) return false;
   int i=colon+1; while(i<StringLen(json)){
      int ch=StringGetChar(json,i);
      if(ch==' '||ch=='\t'||ch=='\r'||ch=='\n') i++; else break;
   }
   int start=i;
   while(i<StringLen(json)){
      int ch2=StringGetChar(json,i);
      if(ch2==','||ch2=='}'||ch2==']') break;
      i++;
   }
   outNum=StringToDouble(Trim(StringSubstr(json,start,i-start)));
   return true;
}

/* -------- Parse "cur" array: levels with type/price/touches ------- */
void ParseCurLevels(const string body,int startPos){
   ArrayResize(g_levels,0);
   int curPos = StringFind(body,"\"cur\"",startPos);
   if(curPos<0) return;
   int arrStart = StringFind(body,"[",curPos); if(arrStart<0) return;
   int arrEnd   = StringFind(body,"]",arrStart); if(arrEnd<0) return;

   int p = arrStart;
   while(true){
      int typePos = StringFind(body,"\"type\"",p);
      if(typePos<0 || typePos>arrEnd) break;

      // find enclosing object end to cap searches
      int objStart = StringFind(body,"{",typePos); if(objStart<0 || objStart>arrEnd) break;
      int objEnd   = StringFind(body,"}",objStart); if(objEnd<0 || objEnd>arrEnd) objEnd=arrEnd;

      string t=""; double pr=0, tou=0;
      JsonGetStringLocal(body,objStart,"type",t);
      JsonGetNumberLocal(body,objStart,"price",pr);
      JsonGetNumberLocal(body,objStart,"touches",tou);

      SRLevel lvl; lvl.kind=t; lvl.price=pr; lvl.touches=(int)MathRound(tou);
      int n=ArraySize(g_levels); ArrayResize(g_levels,n+1); g_levels[n]=lvl;

      p = objEnd+1;
   }
}

/* --- Parse reg.mid/up/dn blocks: t1,y1,t2,y2 (strings+numbers) --- */
bool ParseRegBlock(const string body,const string key){
   // locate "reg" first
   int regPos = StringFind(body,"\"reg\"",0);
   if(regPos<0) return false;
   int kPos = StringFind(body,"\""+key+"\"",regPos);
   if(kPos<0) return false;
   int objStart = StringFind(body,"{",kPos); if(objStart<0) return false;

   string t1s="", t2s=""; double y1=0,y2=0;
   if(!JsonGetStringLocal(body,objStart,"t1",t1s)) return false;
   if(!JsonGetNumberLocal(body,objStart,"y1",y1))  return false;
   if(!JsonGetStringLocal(body,objStart,"t2",t2s)) return false;
   if(!JsonGetNumberLocal(body,objStart,"y2",y2))  return false;

   datetime dt1=ParseIsoTime(t1s);
   datetime dt2=ParseIsoTime(t2s);

   if(key=="mid"){ g_reg_t1=dt1; g_reg_y1_mid=y1; g_reg_t2=dt2; g_reg_y2_mid=y2; }
   else if(key=="up"){ g_reg_y1_up=y1; g_reg_y2_up=y2; }
   else if(key=="dn"){ g_reg_y1_dn=y1; g_reg_y2_dn=y2; }
   return true;
}

/* --- Parse swing.top / swing.bot: t1,y1,t2,y2 --------------------- */
bool ParseSwingSide(const string body,const string side){
   int swPos = StringFind(body,"\"swing\"",0);
   if(swPos<0) return false;
   int kPos = StringFind(body,"\""+side+"\"",swPos);
   if(kPos<0) return false;
   int objStart = StringFind(body,"{",kPos); if(objStart<0) return false;

   string t1s="", t2s=""; double y1=0,y2=0;
   if(!JsonGetStringLocal(body,objStart,"t1",t1s)) return false;
   if(!JsonGetNumberLocal(body,objStart,"y1",y1))  return false;
   if(!JsonGetStringLocal(body,objStart,"t2",t2s)) return false;
   if(!JsonGetNumberLocal(body,objStart,"y2",y2))  return false;

   datetime dt1=ParseIsoTime(t1s);
   datetime dt2=ParseIsoTime(t2s);

   if(side=="top"){ g_sw_top_t1=dt1; g_sw_top_y1=y1; g_sw_top_t2=dt2; g_sw_top_y2=y2; }
   else { g_sw_bot_t1=dt1; g_sw_bot_y1=y1; g_sw_bot_t2=dt2; g_sw_bot_y2=y2; }
   return true;
}

/* ========================== Drawing Helpers ====================== */
void DrawHLine(long chart_id,const string name,double price,color col,int width){
   if(ObjectFind(chart_id,name)==-1)
      ObjectCreate(chart_id,name,OBJ_HLINE,0,0,0);
   ObjectSetDouble (chart_id,name,OBJPROP_PRICE,price);
   ObjectSetInteger(chart_id,name,OBJPROP_COLOR,col);
   ObjectSetInteger(chart_id,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(chart_id,name,OBJPROP_STYLE,InpSRStyle);
   ObjectSetInteger(chart_id,name,OBJPROP_BACK,false);
   ObjectSetInteger(chart_id,name,OBJPROP_SELECTABLE,false);
}

void DrawTrendSegment(long chart_id,const string name,
                      datetime t1,double y1,datetime t2,double y2,
                      color col,int width)
{
   if(ObjectFind(chart_id,name)==-1)
      ObjectCreate(chart_id,name,OBJ_TREND,0,t1,y1,t2,y2);

   ObjectSetInteger(chart_id, name, OBJPROP_TIME1, (long)t1);
   ObjectSetDouble (chart_id, name, OBJPROP_PRICE1, y1);
   ObjectSetInteger(chart_id, name, OBJPROP_TIME2, (long)t2);
   ObjectSetDouble (chart_id, name, OBJPROP_PRICE2, y2);
   ObjectSetInteger(chart_id, name, OBJPROP_COLOR, col);
   ObjectSetInteger(chart_id, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(chart_id, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(chart_id, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(chart_id, name, OBJPROP_SELECTABLE, false);
}

/* Delete previously drawn objects with a prefix */
void DeleteWithPrefix(long chart_id,const string pref){
   int total=ObjectsTotal(chart_id,-1,-1);
   for(int i=total-1;i>=0;i--){
      string nm=ObjectName(chart_id,i);
      if(StringFind(nm,pref,0)==0) ObjectDelete(chart_id,nm);
   }
}

/* ============================ Rendering ========================== */
void RenderOnChart(long chart_id,const string sym)
{
   string pref = g_ns+"_"+sym+"_";

   // Clear previous drawings for this symbol
   DeleteWithPrefix(chart_id, pref);

   // 1) S/R levels
   if(InpShowSR){
      int n = MathMin(ArraySize(g_levels), InpSRMaxLevels);
      for(int i=0;i<n;i++){
         string tl = g_levels[i].kind; // "S" or "R"
         double p  = g_levels[i].price;
         int k     = g_levels[i].touches;

         // styling by touches
         color col = (k>=3 ? InpSRColorHeavy : InpSRColorLight);
         int   wid = (k>=3 ? InpSRWidthHeavy : InpSRWidthLight);

         string name = pref + "SR_" + (tl=="S" ? "S" : "R") + "_" + IntegerToString(i);
         DrawHLine(chart_id, name, p, col, wid);
      }
   }

   // 2) Regression channel
   if(InpShowRegression && g_hasReg){
      DrawTrendSegment(chart_id, pref+"REG_MID", g_reg_t1,g_reg_y1_mid, g_reg_t2,g_reg_y2_mid, InpRegMidColor, InpRegWidth);
      DrawTrendSegment(chart_id, pref+"REG_UP",  g_reg_t1,g_reg_y1_up,  g_reg_t2,g_reg_y2_up,  InpRegUpColor,  InpRegWidth);
      DrawTrendSegment(chart_id, pref+"REG_DN",  g_reg_t1,g_reg_y1_dn,  g_reg_t2,g_reg_y2_dn,  InpRegDnColor,  InpRegWidth);
   }

   // 3) Swing structure
   if(InpShowSwing && g_hasSwing){
      DrawTrendSegment(chart_id, pref+"SW_TOP", g_sw_top_t1,g_sw_top_y1, g_sw_top_t2,g_sw_top_y2, InpSwingTopColor, InpSwingWidth);
      DrawTrendSegment(chart_id, pref+"SW_BOT", g_sw_bot_t1,g_sw_bot_y1, g_sw_bot_t2,g_sw_bot_y2, InpSwingBotColor, InpSwingWidth);
   }
}

/* ============================ Networking ========================= */
string BuildHeaders(){
   string h="";
   h += "X-RapidAPI-Key: "+InpRapidAPIKey+"\r\n";
   h += "X-RapidAPI-Host: "+InpRapidAPIHost+"\r\n";
   h += "Accept: application/json\r\n";
   return h;
}

bool FetchLatestSupRes(const string sym)
{
   string url = "https://" + InpRapidAPIHost + InpApiPath + "?symbol=" + sym + "&latest=1";

   char data[]; char result[]; string hdrs;
   int status = WebRequest("GET", url, BuildHeaders(), InpTimeoutMs, data, result, hdrs);

   if(status==-1){
      int err = GetLastError();
      Comment("WebRequest error: ", err, "\nWhitelist URL in Tools>Options>Expert Advisors:\nhttps://", InpRapidAPIHost);
      return false;
   }

   string body = CharArrayToString(result,0,-1);

   if(status!=200){
      Comment("HTTP ", status, ": ", body);
      return false;
   }

   // Expect shape: { kind:"latest", snapshot:{ cur:[...], reg:{mid,up,dn}, swing:{top,bot}}, symbol:"...", opentime:"..." }
   // 1) symbol / opentime
   string symOut="";
   if(JsonGetStringLocal(body,0,"symbol",symOut)) g_lastSymbol=symOut; else g_lastSymbol=sym;
   string ot="";
   if(JsonGetStringLocal(body,0,"opentime",ot)) g_lastOpenTime=ot;

   // 2) cur levels
   ParseCurLevels(body,0);

   // 3) regression
   bool okMid = ParseRegBlock(body,"mid");
   bool okUp  = ParseRegBlock(body,"up");
   bool okDn  = ParseRegBlock(body,"dn");
   g_hasReg = (okMid && okUp && okDn);

   // 4) swing
   bool okTop = ParseSwingSide(body,"top");
   bool okBot = ParseSwingSide(body,"bot");
   g_hasSwing = (okTop && okBot);

   return true;
}

/* ============================ Multi-Chart ========================= */
void RenderAllChartsOrCurrent(){
   // symbol we fetched for
   string sym = (g_lastSymbol=="" ? (InpSymbolOverride=="" ? _Symbol : InpSymbolOverride) : g_lastSymbol);

   if(!InpApplyToAllCharts){
      RenderOnChart(0, sym);   // only current chart
      return;
   }

   // MT4: iterate open charts using ChartFirst/ChartNext
   long cid = ChartFirst();
   while(cid != -1)
   {
      string csym = ChartSymbol(cid);
      if(csym == sym)
         RenderOnChart(cid, sym);

      cid = ChartNext(cid);
   }
}

/* ============================== Hooks ============================ */
bool ShouldFetchNow(){
   if(InpFetchOnNewBar){
      datetime bt = iTime(NULL, PERIOD_CURRENT, 0);
      if(bt!=0 && bt!=g_lastBarTime){
         if((TimeCurrent()-g_lastFetchAt) >= InpMinFetchSecs){
            g_lastBarTime = bt;
            return true;
         }
      }
      return false;
   }
   // timer/interval mode
   return (TimeCurrent()-g_lastFetchAt) >= InpMinFetchSecs;
}

int OnInit(){
   g_lastBarTime = iTime(NULL,PERIOD_CURRENT,0);
   EventSetTimer(MathMax(10, InpMinFetchSecs));

   string sym = (InpSymbolOverride=="" ? _Symbol : InpSymbolOverride);
   if(FetchLatestSupRes(sym)){
      RenderAllChartsOrCurrent();
      g_lastFetchAt = TimeCurrent();
      Comment("darwintIQ SupRes (", sym, ") as of ", g_lastOpenTime);
   }else{
      // keep going; timer will retry
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   EventKillTimer();
   // Clean only objects for current symbol on current chart if not multi-chart.
   // For safety, remove all our prefixed objects from current chart.
   DeleteWithPrefix(0, g_ns+"_");
   Comment("");
}

void OnTick(){
   if(!InpFetchOnNewBar) return;
   if(ShouldFetchNow()){
      string sym = (InpSymbolOverride=="" ? _Symbol : InpSymbolOverride);
      if(FetchLatestSupRes(sym)){
         RenderAllChartsOrCurrent();
         g_lastFetchAt = TimeCurrent();
         Comment("darwintIQ SupRes (", sym, ") as of ", g_lastOpenTime);
      }
   }
}

void OnTimer(){
   if(ShouldFetchNow()){
      string sym = (InpSymbolOverride=="" ? _Symbol : InpSymbolOverride);
      if(FetchLatestSupRes(sym)){
         RenderAllChartsOrCurrent();
         g_lastFetchAt = TimeCurrent();
         Comment("darwintIQ SupRes (", sym, ") as of ", g_lastOpenTime);
      }
   }
}
//+------------------------------------------------------------------+
