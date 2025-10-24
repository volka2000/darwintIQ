//+------------------------------------------------------------------------------------------+
//|                        darwintIQ_TrendMatrixEA.mq4                                       |
//|  See more: https://rapidapi.com/darwintiq-darwintiq-default/api/darwintiq-trendmatrix    |
//+------------------------------------------------------------------------------------------+
#property strict

/* ============================== Inputs ============================== */
// RapidAPI
input string InpRapidAPIHost   = "darwintiq-trendmatrix.p.rapidapi.com";
input string InpRapidAPIKey    = "YOUR_RAPIDAPI_KEY";
input string InpApiPath        = "/api/rapidapi/trendmatrix/v1";
input string InpSymbol         = "";     // symbol (empty = current chart symbol)

// Fetch timing
input int    InpMinFetchSecs   = 60;     // minimum seconds between API calls
input int    InpTimeoutMs      = 8000;   // WebRequest timeout
input bool   InpFetchOnNewBar  = true;   // fetch when a new bar appears
input bool   InpShowInComment  = false;  // show short info in the chart comment

// Layout (panel position)
input int    InpCorner         = 1;      // 0=LT, 1=RT, 2=LB, 3=RB
input int    InpX              = 12;     // panel margin X
input int    InpY              = 12;     // panel margin Y
input int    InpGap            = 10;     // distance between tiles

// Tile size / font
input int    InpTileW          = 200;
input int    InpTileH          = 56;
input int    InpFontSize       = 10;
input string InpFontName       = "Arial"; // plain font (icons removed)

// Colors (flat)
input color  InpTileBg         = clrWhite;
input color  InpTileBorder     = clrGainsboro;
input color  InpText           = clrDimGray;
input color  InpPillBullBg     = clrHoneydew;
input color  InpPillBullText   = clrLimeGreen;
input color  InpPillBearBg     = clrMistyRose;
input color  InpPillBearText   = clrTomato;
input color  InpPillRangeBg    = clrAliceBlue;
input color  InpPillRangeText  = clrSlateGray;
input color  InpBarEmpty       = clrLavender;
input color  InpBarBull        = clrLimeGreen;
input color  InpBarBear        = clrTomato;

/* ============================== Globals ============================= */
datetime g_lastBarTime = 0;
datetime g_lastFetchAt = 0;

string   g_ns          = "darwintIQ_TMX";

string   g_consensus   = "NEUTRAL";
string   g_asOf        = "";
string   g_sym         = "";

// Timeframe data
string g_dir_M1="Ranging";   int g_str_M1=0;
string g_dir_M5="Ranging";   int g_str_M5=0;
string g_dir_M15="Ranging";  int g_str_M15=0;
string g_dir_M30="Ranging";  int g_str_M30=0;
string g_dir_H1="Ranging";   int g_str_H1=0;
string g_dir_H4="Ranging";   int g_str_H4=0;
string g_dir_D1="Ranging";   int g_str_D1=0;
string g_dir_W1="Ranging";   int g_str_W1=0;

// Panel geometry (always Corner=0 coordinates)
int g_originX = 0;
int g_originY = 0;
int g_panelW  = 0;
int g_panelH  = 0;

/* ============================== Utils =============================== */
string Trim(const string s) {
   string t = s;
   int i=0; while(i<StringLen(t)) { int c=StringGetChar(t,i); if(c==' '||c=='\t'||c=='\r'||c=='\n') i++; else break; }
   if(i>0) t=StringSubstr(t,i);
   while(StringLen(t)>0) { int c2=StringGetChar(t,StringLen(t)-1); if(c2==' '||c2=='\t'||c2=='\r'||c2=='\n') t=StringSubstr(t,0,StringLen(t)-1); else break; }
   return t;
}
string Lower(const string s){ string t=s; StringToLower(t); return t; }

bool JsonGetStringLocal(const string json,int from,const string key,string &outVal){
   string needle="\""+key+"\"";
   int pos=StringFind(json,needle,from); if(pos<0) return false;
   int colon=StringFind(json,":",pos); if(colon<0) return false;
   int q1=StringFind(json,"\"",colon+1); if(q1<0) return false;
   int q2=StringFind(json,"\"",q1+1); if(q2<0) return false;
   outVal=StringSubstr(json,q1+1,q2-(q1+1));
   return true;
}
bool JsonGetNumberLocal(const string json,int from,const string key,double &outNum){
   string needle="\""+key+"\"";
   int pos=StringFind(json,needle,from); if(pos<0) return false;
   int colon=StringFind(json,":",pos); if(colon<0) return false;
   int i=colon+1; while(i<StringLen(json)){ int ch=StringGetChar(json,i); if(ch==' '||ch=='\t'||ch=='\r'||ch=='\n') i++; else break; }
   int start=i; while(i<StringLen(json)){ int ch2=StringGetChar(json,i); if(ch2==','||ch2=='}'||ch2==']') break; i++; }
   outNum=StringToDouble(Trim(StringSubstr(json,start,i-start)));
   return true;
}

string BuildHeaders(){
   string h="";
   h+="X-RapidAPI-Key: "+InpRapidAPIKey+"\r\n";
   h+="X-RapidAPI-Host: "+InpRapidAPIHost+"\r\n";
   h+="Accept: application/json\r\n";
   return h;
}

color PillBgForDir(const string d){ string x=Lower(d); if(x=="bullish") return InpPillBullBg; if(x=="bearish") return InpPillBearBg; return InpPillRangeBg; }
color PillTextForDir(const string d){ string x=Lower(d); if(x=="bullish") return InpPillBullText; if(x=="bearish") return InpPillBearText; return InpPillRangeText; }

/* ========================== Panel Geometry ========================== */
void ComputePanelGeometry(){
   // 2 columns × 4 rows + header
   g_panelW = InpTileW*2 + InpGap;
   int headerH = 36;
   g_panelH = headerH + (InpTileH*4) + (InpGap*3);

   long cw=0,ch=0;
   ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0, cw);
   ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0, ch);
   int W=(int)cw, H=(int)ch;

   if(InpCorner==0) { g_originX = InpX;                 g_originY = InpY; }
   else if(InpCorner==1){ g_originX = W - InpX - g_panelW; g_originY = InpY; }
   else if(InpCorner==2){ g_originX = InpX;                 g_originY = H - InpY - g_panelH; }
   else {                 g_originX = W - InpX - g_panelW; g_originY = H - InpY - g_panelH; }
}

/* ============================ JSON parse ============================ */
void ResetTFDefaults(){
   g_dir_M1="Ranging";  g_str_M1=0;
   g_dir_M5="Ranging";  g_str_M5=0;
   g_dir_M15="Ranging"; g_str_M15=0;
   g_dir_M30="Ranging"; g_str_M30=0;
   g_dir_H1="Ranging";  g_str_H1=0;
   g_dir_H4="Ranging";  g_str_H4=0;
   g_dir_D1="Ranging";  g_str_D1=0;
   g_dir_W1="Ranging";  g_str_W1=0;
}

bool ParseTrendMap(const string body){
   int trendPos = StringFind(body,"\"trend\"",0);
   if(trendPos<0) return false;

   ResetTFDefaults();

   #define EXTRACT_TF(TF,dirVar,strVar) {                           \
      int p=StringFind(body,"\"" TF "\"",trendPos);                  \
      if(p>=0){ string d=""; double s=0;                             \
         JsonGetStringLocal(body,p,"dir",d);                         \
         JsonGetNumberLocal(body,p,"strength",s);                    \
         dirVar=(d==""?"Ranging":d);                                 \
         int si=(int)MathRound(s); if(si<0) si=0; if(si>5) si=5;     \
         strVar=si;                                                  \
      }                                                              \
   }

   EXTRACT_TF("M1",g_dir_M1,g_str_M1);
   EXTRACT_TF("M5",g_dir_M5,g_str_M5);
   EXTRACT_TF("M15",g_dir_M15,g_str_M15);
   EXTRACT_TF("M30",g_dir_M30,g_str_M30);
   EXTRACT_TF("H1",g_dir_H1,g_str_H1);
   EXTRACT_TF("H4",g_dir_H4,g_str_H4);
   EXTRACT_TF("D1",g_dir_D1,g_str_D1);
   EXTRACT_TF("W1",g_dir_W1,g_str_W1);

   string c="";  JsonGetStringLocal(body,0,"consensus",c); g_consensus=(c==""?"NEUTRAL":c);
   string ot=""; JsonGetStringLocal(body,0,"opentime",ot); g_asOf=ot;
   string sy=""; JsonGetStringLocal(body,0,"symbol",sy);   g_sym=(sy==""?(InpSymbol==""?_Symbol:InpSymbol):sy);
   return true;
}

/* =========================== Error UI =============================== */
void DeleteInitErrors(){
   string n1 = g_ns + "_err_title";
   string n2 = g_ns + "_err_msg";
   if(ObjectFind(0, n1) != -1) ObjectDelete(0, n1);
   if(ObjectFind(0, n2) != -1) ObjectDelete(0, n2);
}

void DrawError(const string msg){
   ComputePanelGeometry();
   EnsureLabel(g_ns+"_err_title", g_originX, g_originY, "darwintIQ Trend Matrix", InpText, InpFontSize+1);
   EnsureLabel(g_ns+"_err_msg",   g_originX, g_originY+16, msg, clrTomato, InpFontSize);
}

/* =========================== Networking ============================ */
bool FetchLatest(){
   string sym=(InpSymbol==""?_Symbol:InpSymbol);
   string url="https://"+InpRapidAPIHost+InpApiPath+"?symbol="+sym+"&latest=1";

   char data[]; char result[]; string hdrs;
   int status=WebRequest("GET",url,BuildHeaders(),InpTimeoutMs,data,result,hdrs);
   if(status==-1){
      int err=GetLastError();
      string msg="WebRequest error: "+IntegerToString(err)+
                 "\nWhitelist URL in: Tools > Options > Expert Advisors > Allow WebRequest\nhttps://"+InpRapidAPIHost;
      DrawError(msg); if(InpShowInComment) Comment(msg);
      return false;
   }
   string body=CharArrayToString(result,0,-1);
   if(status!=200){
      string msg=StringFormat("HTTP %d\n%s",status,body);
      DrawError(msg); if(InpShowInComment) Comment(msg);
      return false;
   }

   if(!ParseTrendMap(body)){
      string msg="Parse error: unexpected JSON shape.";
      DrawError(msg); if(InpShowInComment) Comment(msg);
      return false;
   }

   DrawPanel();
   DeleteInitErrors();

   if(InpShowInComment)
      Comment(StringFormat("%s | %s | Consensus: %s",(g_sym==""?_Symbol:g_sym),(g_asOf==""?"n/a":g_asOf),g_consensus));

   g_lastFetchAt=TimeCurrent();
   return true;
}

/* =========================== Drawing =============================== */
void EnsureRect(const string name,int x,int y,int w,int h,color bg,color br){
   if(ObjectFind(0,name)==-1){
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,0); // always top-left coordinates
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,name,OBJPROP_CORNER,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);

   // Flat look: only thin border, no 3D
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,br);
}

void EnsureLabel(const string name,int x,int y,const string text,color col,int size,string font=""){
   if(font=="") font=InpFontName;
   if(ObjectFind(0,name)==-1){
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,0);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
   }
   ObjectSetInteger(0,name,OBJPROP_CORNER,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   ObjectSetString (0,name,OBJPROP_FONT,font);
}

void EnsurePill(const string nameBox,const string nameText,int x,int y,const string txt,color bg,color fg){
   int padX=6, padY=2;
   // rough width estimate per character (no icons)
   int w = StringLen(txt)*(InpFontSize-3) + 2*padX;
   int h = InpFontSize + 6;
   EnsureRect(nameBox, x, y, w, h, bg, InpTileBorder);
   EnsureLabel(nameText, x+padX, y+padY, txt, fg, InpFontSize);
}

void StrengthBar(const string baseName,int x,int y,int filled,color bullOrBear){
   int n=5, w=14, h=4, gap=3;
   for(int i=0;i<n;i++){
      string r=baseName+"_b"+IntegerToString(i);
      int xi=x + i*(w+gap);
      color bg=(i<filled ? bullOrBear : InpBarEmpty);
      EnsureRect(r, xi, y, w, h, bg, bg);
   }
}

// Single tile
void DrawTile(const string tf,const string dir,int strength,int x,int y){
   string tile=g_ns+"_tile_"+tf;
   EnsureRect(tile, x, y, InpTileW, InpTileH, InpTileBg, InpTileBorder);

   // Direction pill (text only, no icons)
   string pillTxt=dir;
   color pbg=PillBgForDir(dir);
   color pfg=PillTextForDir(dir);
   EnsurePill(g_ns+"_pill_"+tf, g_ns+"_pilltxt_"+tf, x+62, y+6, pillTxt, pbg, pfg);

   // Labels
   EnsureLabel(g_ns+"_tf_"+tf, x+10, y+6, tf, InpText, InpFontSize+1, InpFontName);
   EnsureLabel(g_ns+"_strlab_"+tf, x+10, y+InpTileH-18, "Strength", InpText, InpFontSize, InpFontName);

   // More horizontal spacing between label and bar
   string dlow=Lower(dir);
   color barColor=(dlow=="bearish"?InpBarBear:InpBarBull);
   if(dlow=="ranging") barColor=InpBarEmpty;

   int barX = x + 110;                // shifted further right for spacing
   int barY = y + InpTileH - 16;
   StrengthBar(g_ns+"_bar_"+tf, barX, barY, MathMax(0,MathMin(5,strength)), barColor);
}

void DrawHeader(){
   EnsureLabel(g_ns+"_title", g_originX, g_originY, "Trend Matrix", InpText, InpFontSize+2, InpFontName);
   string sub=StringFormat("%s   as of %s",(g_sym==""?_Symbol:g_sym),(g_asOf==""?"n/a":g_asOf));
   EnsureLabel(g_ns+"_sub",   g_originX, g_originY+18, sub, InpText, InpFontSize, InpFontName);

   
}

void DrawPanel(){
   ComputePanelGeometry();
   DrawHeader();

   int baseY = g_originY + 36;
   int col1x = g_originX;
   int col2x = g_originX + InpTileW + InpGap;

   DrawTile("M1",  g_dir_M1,  g_str_M1,  col1x, baseY + 0*(InpTileH+InpGap));
   DrawTile("M5",  g_dir_M5,  g_str_M5,  col1x, baseY + 1*(InpTileH+InpGap));
   DrawTile("M15", g_dir_M15, g_str_M15, col1x, baseY + 2*(InpTileH+InpGap));
   DrawTile("M30", g_dir_M30, g_str_M30, col1x, baseY + 3*(InpTileH+InpGap));

   DrawTile("H1",  g_dir_H1,  g_str_H1,  col2x, baseY + 0*(InpTileH+InpGap));
   DrawTile("H4",  g_dir_H4,  g_str_H4,  col2x, baseY + 1*(InpTileH+InpGap));
   DrawTile("D1",  g_dir_D1,  g_str_D1,  col2x, baseY + 2*(InpTileH+InpGap));
   DrawTile("W1",  g_dir_W1,  g_str_W1,  col2x, baseY + 3*(InpTileH+InpGap));
}

/* =========================== Scheduling ============================ */
bool ShouldFetchNow(){
   if(InpFetchOnNewBar){
      datetime t0=iTime(NULL,PERIOD_CURRENT,0);
      if(t0!=0 && t0!=g_lastBarTime){
         if((TimeCurrent()-g_lastFetchAt)>=InpMinFetchSecs){
            g_lastBarTime=t0;
            return true;
         }
      }
   }
   return false;
}

/* ============================ MT4 Hooks ============================ */
int OnInit(){
   g_lastBarTime=iTime(NULL,PERIOD_CURRENT,0);
   EventSetTimer(MathMax(10,InpMinFetchSecs));
   // No "Initializing…" label; only show errors when needed
   FetchLatest();
   // Ensure no stale error labels remain
   DeleteInitErrors();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   EventKillTimer();
   int total=ObjectsTotal(0,-1,-1);
   for(int i=total-1;i>=0;i--){
      string nm=ObjectName(0,i);
      if(StringFind(nm,g_ns,0)==0) ObjectDelete(0,nm);
   }
   if(InpShowInComment) Comment("");
}

void OnTick(){
   if(!InpFetchOnNewBar) return;
   if(ShouldFetchNow()) FetchLatest();
}

void OnTimer(){
   if((TimeCurrent()-g_lastFetchAt)>=InpMinFetchSecs) FetchLatest();
}
