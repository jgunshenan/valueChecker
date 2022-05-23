/*--------------------------- Seattle Genetics Standard Program Header ---------------------------*
|         Program Name: O:\Projects\iSAFE\utilities\autocall\mcr_isafe_value_checker_ss
|  Operating System(s): Windows Server 2012
|          SAS Version: 9.4
|               Author: jpg
|              Purpose: Make spreadsheet from mcr_isafe_value_checker output datasets

|  Inputs Path\Name(s): current.ddiffcont&debugsuffix current.ddiffcat&debugsuffix
|                       
| Outputs Path\Name(s): in current dir, ddiff&debugsuffix..xlsx" 
|
| Notes: Had to separate spreadsheet creation from dataset creation to avoid out-of-memory issues in SAS.
|                       
| Macro Parameters: 
|                       
|  Mod. Date   User Name      Modification
|  04MAR2022   jpg            ODS excel & proc report method. Works for small scans, but runs out of memory
|                             on pooled.  Checking in for reference only.  
|  04MAR2022   jpg            ODS excel & proc report method for all but categoricals & Contents.  libname 
|                             excel engine method for categoricals.  This tab is not polished, but it doesnt
|                             run out of memory trying to build the spreadsheet.
|                             
|------------------------------------------------------------------------------------------------*/


%macro memavail(logmsg);
  data _null_;
    mem = input(getoption('xmrlmem'),20.2)/10e6;
    format mem 20.2;
    putlog "You have " mem "GB memory available. &logmsg";
	call symput ("MEMAVAIL", strip(vvalue(mem)));
  run;
%mend;

%memavail(%str(before macro def));
 
%macro mcr_isafe_value_checker_ss(OUTPATH=,
                                  DDIFFDSPATH=,
								  OUTSUFFIX=,
								  LIMITMEM=3);

  %if %length(&OUTPATH)=0 %then %do; %let outpath=%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived\testing\freqout); %end;
                          %else %do; %let outpath=&OUTPATH; %end;
  %if %length(&DDIFFDSPATH)=0 %then %do; libname _inlib "O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived\testing\freqout"; %end;
                              %else %do; libname _inlib "&DDIFFDSPATH"; %end;
  						  
  title;
  ods excel file="&outpath\ddiff&OUTSUFFIX..xlsx" options(embedded_titles="on" embed_titles_once="on" autofilter="all" frozen_headers="on");	
    
  %let UNIQBVLSTF=;  
  %let UNIQBVLSTM=;
  data mycover;
    set _inlib.ddiffcvr&OUTSUFFIX end=eof;
	label name = "Names:"
	      value = "Values:";
	if name="  Spreadsheet Input Read From:"   then value="&DDIFFDSPATH";
	if name="  Spreadsheet Output Written To:" then value="&outpath\ddiff&OUTSUFFIX..xlsx";
	if name="Time of Spreadsheet Build Start:" then value=put(datetime(),datetime.); 
	if strip(name) = "Categorical By Variables" then call symput("UNIQBVLSTF", strip(value));
	if strip(name) = "Numeric By Variables"     then call symput("UNIQBVLSTM", strip(value));
	output;
	if eof then do; ord=200; name="  LIMITMEM: Limit Memory Usage Building Spreadsheets (0-3)";    value="&LIMITMEM"; output;
	                ord=201; name="    LIMITMEM=0 -> Pretty Spreadsheets";           output;
	                ord=202; name="    LIMITMEM>0 -> Ugly AllContents Spreadsheet";  output;
	                ord=203; name="    LIMITMEM>1 -> Ugly ChgNumValues Spreadsheet"; output;
	                ord=204; name="    LIMITMEM>2 -> Ugly ChgCatValues Spreadsheet"; output;
					end;
  run;
  
  data _null_;
    length bv4f bv4m defbv4m defbv4f $200 delims $5;
	delims=' 	,';
	bv4f="&UNIQBVLSTF";
	bv4m="&UNIQBVLSTM";
	defbv4f='';
    numbvars=countw(bv4f, delims);
	do bvindx=1 to numbvars;
	  byvar=scan(bv4f, bvindx, delims);
	  defbv4f=catx(' ', "define", byvar, "/display flow width=10;");
	  end;
	defbv4m='';
    numbvars=countw(bv4m, delims);
	do bvindx=1 to numbvars;
	  byvar=scan(bv4m, bvindx, delims);
	  defbv4m=catx(' ', "define", byvar, "/display flow width=10;");
	  end;
	call symput("DEFBYVARS4M", strip(defbv4m));
    call symput("DEFBYVARS4F", strip(defbv4f));
  run;
  
  %PUT DEFBYVARS4M: &DEFBYVARS4M;
  %PUT DEFBYVARS4F: &DEFBYVARS4F;

  
  ods excel options(sheet_name="Cover"
                   /*autofilter = "1-7"*/
				   /*frozen_rowheaders = "2"*/
                   frozen_headers = "on"
                   );			 
				 proc report data=mycover split='~' style(header)=[textalign=left verticalalign=top]; 
                   column name value ;
				   define name   /display flow width=40 style(column)=[asis=on];
				   define value  /display flow width=200 style(column)=[asis=on];
                 run;
  proc datasets lib=work noprint; delete mycover; run;
   


  ods excel options(sheet_name="Studies"
                   autofilter = "1-4"
				   frozen_rowheaders = "1"
                   frozen_headers = "on"
                   );			 
				 proc report data=_inlib.ddiffstdys&OUTSUFFIX split='~' style(header)=[textalign=left verticalalign=top]; 
                   column fname actvstdyfl inold innew;
				   define fname /display flow width=25 "Study Dir Name";
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define inold /display width=4 "In Old Study" style(column)=[textalign=center];
				   define innew /display width=4 "In New Study" style(column)=[textalign=center];
                 run;
  

  ods excel options(sheet_name="dDsets"
                    autofilter = "1-8"
				    frozen_rowheaders = "1"
				    row_heights = "42"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffdsets&OUTSUFFIX split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname innew inold newmodate oldmodate deltamodate;
				   define stdynamS    /display flow width=25;
				   define actvstdyfl  /display width=4 style(column)=[textalign=center];
				   define dsname      /display flow width=25;
				   define innew       /display flow width=4 style(column)=[textalign=center];
				   define inold       /display width=4 style(column)=[textalign=center];
				   define newmodate   /display width=16;
				   define oldmodate    /display width=16;
				   define deltamodate /display width=4;
                 run;
  
				   
  ods excel options(sheet_name="dLength"
                    autofilter = "1-6"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX(where=(chlenfl='Y')) split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname varname oldlength newlength;
				   define actvstdyfl /display width=4 "Study Name" style(column)=[textalign=center];
				   define stdynamS /display flow width=10;
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define oldlength   /display width=4;
				   define newlength   /display width=4;
                 run;

  ods excel options(sheet_name="dLabel"
                    autofilter = "1-6"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX(where=(chlabfl='Y')) split='~'; 
                   column stdynamS actvstdyfl dsname varname oldlabel newlabel;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define stdynamS /display flow width=10;
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define oldlabel   /display width=40 style(column)=[asis=on];
				   define newlabel   /display width=40 style(column)=[asis=on];
                 run;
				 
  ods excel options(sheet_name="dType"
                    autofilter = "1-8"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX(where=(chtypfl='Y')) split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname varname oldtypec newtypec oldtype newtype;
				   define stdynamS /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define oldtypec   /display width=4;
				   define newtypec   /display width=4;
				   define oldtype   /display width=4;
				   define newtype   /display width=4;
                 run;
				 
  ods excel options(sheet_name="dFormat"
                    autofilter = "1-6"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX(where=(chfmtfl='Y')) split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname varname oldformat newformat;
				   define stdynamS /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define oldformat   /display width=4;
				   define newformat   /display width=4;
                 run;
				 				 
  ods excel options(sheet_name="dInfmt"
                    autofilter = "1-6"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX(where=(chinffl='Y')) split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname varname oldinfmt newinfmt;
				   define stdynamS /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define oldinfmt   /display width=4;
				   define newinfmt   /display width=4;
                 run;						 	
				 
  data myurgc;
    retain stdynamS actvstdyfl dsname &UNIQBVLSTF varname critvarfl inCTfl percentage pctcat delta deltacat oldcount newcount cvalstat catval;
    set _inlib.ddiffurgc&OUTSUFFIX(keep=stdynamS actvstdyfl dsname &UNIQBVLSTF varname critvarfl inCTfl percentage pctcat delta deltacat oldcount newcount cvalstat catval) end=eof;
  run;
  
  ods excel options(sheet_name="UrgentCat"
                    autofilter = "1-15"
				    frozen_rowheaders = "1"
				    row_heights = "42"
                    frozen_headers = "on");			 
				 proc report data=myurgc split='~' style(header)=[textalign=left verticalalign=top]; 
				   column stdynamS actvstdyfl dsname varname critvarfl inCTfl &UNIQBVLSTF percentage pctcat delta deltacat oldcount newcount cvalstat catval;
				   define stdynamS   /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   &DEFBYVARS4F;
				   define critvarfl  /display width=4 style(column)=[textalign=center];
				   define inCTFL     /display width=4 style(column)=[textalign=center];
				   define pctcat     /display width=10;
				   define deltacat   /display width=6;
				   define percentage /display width=4;
				   define delta      /display width=4;
				   define oldcount   /display width=4;
				   define newcount   /display width=4;
				   define cvalstat   /display width=4;
				   define catval     /display flow width=40 style(column)=[asis=on];
                 run;		
				 
  proc datasets lib=work noprint; delete myurgc; run;
  

  data mymcat;
    retain stdynamS actvstdyfl dsname &UNIQBVLSTF varname critvarfl inCTfl pctcat delta deltacat oldcount newcount cvalstat catval;
    set _inlib.ddiffmcat&OUTSUFFIX(keep=stdynamS actvstdyfl dsname varname &UNIQBVLSTF critvarfl inCTfl pctcat delta deltacat oldcount newcount cvalstat catval) end=eof;
  run;
  
  ods excel options(sheet_name="MissingCat"
                    autofilter = "1-12"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=mymcat split='~' style(header)=[textalign=left verticalalign=top]; 
				   column stdynamS actvstdyfl dsname varname &UNIQBVLSTF critvarfl inCTfl  oldcount newcount catval;
				   define stdynamS   /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   &DEFBYVARS4F;
				   define critvarfl  /display width=4 style(column)=[textalign=center];
				   define inCTFL     /display width=4 style(column)=[textalign=center];
				   define oldcount   /display width=4;				   
				   define newcount   /display width=4;
				   define catval     /display flow width=40 style(column)=[asis=on];
                 run;		

			proc datasets lib=work noprint; delete mymcat; run;
  

  
  data myurgn;
    set _inlib.ddiffurgn&OUTSUFFIX;
	label inold          = "In Old Dataset Flag"
          innew          = "In New Dataset Flag"
          oldn           =     "Old N"
          newn           =     "New N"
          deltan         =   "Delta N"
          deltancat      =   "Delta N Category"
          pctn           = "Percent N" 
          pctncat        = "Percent N Category"
          oldmean        =     "Old Mean" 
          newmean        =     "New Mean" 
          deltamean      =   "Delta Mean" 
          deltameancat   =   "Delta Mean Category" 
          pctmean        = "Percent Mean"
          pctmeancat     = "Percent Mean Category" 
          oldmedian      =     "Old Median"
          newmedian      =     "New Median"
          deltamedian    =   "Delta Median" 
          deltamediancat =   "Delta Median Category" 
          pctmedian      = "Percent Median" 
          pctmediancat   = "Percent Median Category" 
          oldmax         =     "Old Max"
          newmax         =     "New Max"
          deltamax       =   "Delta Max" 
          deltamaxcat    =   "Delta Max Category" 
          pctmax         = "Percent Max" 
          pctmaxcat      = "Percent Max Category" 
          oldmin         =     "Old Min"
		  newmin         =     "New Min"
          deltamin       =   "Delta Min" 
          deltamincat    =   "Delta Min Category" 
          pctmin         = "Percent Min" 
          pctmincat      = "Percent Min Category" 
          oldrange       =     "Old Range"
          newrange       =     "New Range"
          deltarange     =   "Delta Range" 
          deltarangecat  =   "Delta Range Category" 
          pctrange       = "Percent Range"
          pctrangecat    = "Percent Range Category" 
          oldstddev      =     "Old Std Dev"
          newstddev      =     "New Std Dev"
          deltastddev    =   "Delta Std Dev" 
          deltastddevcat =   "Delta Std Dev Category"  
          pctstddev      = "Percent Std Dev" 
          pctstddevcat   = "Percent Std Dev Category";
  run;
  

  
  %let NUMCOLORD = stdynamS actvstdyfl dsname &UNIQBVLSTM varname label critvarfl mvalstat 
				   newn newnmiss newmean newmedian newmax newmin newrange newstddev
				   oldn oldnmiss oldmean oldmedian oldmax oldmin oldrange oldstddev
				   deltancat      pctncat      deltan      pctn
				   deltanmisscat  pctnmisscat  deltanmiss  pctnmiss     
				   deltameancat   pctmeancat   deltamean   pctmean 
				   deltamediancat pctmediancat deltamedian pctmedian
				   deltamaxcat    pctmaxcat    deltamax    pctmax
				   deltamincat    pctmincat    deltamin    pctmin
				   deltarangecat  pctrangecat  deltarange  pctrange
				   deltastddevcat pctstddevcat deltastddev pctstddev
				   innew inold;
  %let NUMCOLORD = stdynamS actvstdyfl dsname &UNIQBVLSTM varname label critvarfl mvalstat inold innew 
                   oldn newn deltan deltancat pctn pctncat oldnmiss newnmiss deltanmiss deltanmisscat pctnmiss pctnmisscat 
				   oldmean newmean deltamean deltameancat pctmean pctmeancat 
                   oldmedian newmedian deltamedian deltamediancat pctmedian pctmediancat oldmax newmax deltamax deltamaxcat pctmax pctmaxcat
                   oldmin newmin deltamin deltamincat pctmin pctmincat oldrange newrange deltarange deltarangecat pctrange pctrangecat
                   oldstddev newstddev deltastddev deltastddevcat pctstddev pctstddevcat;

  
  ods excel options(sheet_name="UrgentNum"
                    autofilter = "1-61"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=myurgn split='~' style(header)=[textalign=left verticalalign=top]; 
				   column &NUMCOLORD;
				   define stdynamS   /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   define label      /display flow width=10;
				   &DEFBYVARS4M;				   
				   define critvarfl  /display width=4 style(column)=[textalign=center];
				   define mvalstat   /display width=4;
				   
				   define newn      /display width=4;
				   define newmean   /display width=4;
				   define newmedian /display width=4;
				   define newmax    /display width=4;
				   define newmin    /display width=4;
				   define newrange  /display width=4;
				   define newstddev /display width=4;
				   define oldn      /display width=4;
				   define oldmean   /display width=4;
				   define oldmedian /display width=4;
				   define oldmax    /display width=4;
				   define oldmin    /display width=4;
				   define oldrange  /display width=4;
				   define oldstddev /display width=4;	
				   
				   define newnmiss  /display width=4;
				   define oldnmiss  /display width=4;
				   define pctnmiss    /display width=4;
				   define deltanmiss  /display width=4;
				   define pctnmisscat    /display width=10;
				   define deltanmisscat  /display width=6;

				   define pctn        /display width=4;
				   define pctmean     /display width=4;
				   define pctmedian   /display width=4;
				   define pctmax      /display width=4;
				   define pctmin      /display width=4;
				   define pctrange    /display width=4;
				   define pctstddev   /display width=4;
				   define deltan      /display width=4;
				   define deltamean   /display width=4;
				   define deltamedian /display width=4;
				   define deltamax    /display width=4;
				   define deltamin    /display width=4;
				   define deltarange  /display width=4;
				   define deltastddev /display width=4;
				   
				   define pctncat        /display width=10;
				   define pctmeancat     /display width=10;
				   define pctmediancat   /display width=10;
				   define pctmaxcat      /display width=10;
				   define pctmincat      /display width=10;
				   define pctrangecat    /display width=10;
				   define pctstddevcat   /display width=10;
				   define deltancat      /display width=6;
				   define deltameancat   /display width=6;
				   define deltamediancat /display width=6;
				   define deltamaxcat    /display width=6;
				   define deltamincat    /display width=6;
				   define deltarangecat  /display width=6;
				   define deltastddevcat /display width=6;
				   
				   define innew   /display width=4 style(column)=[textalign=center];
;
				   define inold   /display width=4 style(column)=[textalign=center];
                 run;	

		 proc datasets lib=work noprint; delete myurgn; run;
  


  data mymnum;
    set _inlib.ddiffmnum&OUTSUFFIX;
  run;
  
  ods excel options(sheet_name="MissingNum"
                    autofilter = "1-61"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=mymnum split='~' style(header)=[textalign=left verticalalign=top]; 
				   column &NUMCOLORD;
				   define stdynamS   /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   define label      /display flow width=10;
				   &DEFBYVARS4M;
				   define critvarfl  /display width=4 style(column)=[textalign=center];
				   define mvalstat   /display width=4;
				   
				   define newn      /display width=4;
				   define newnmiss  /display width=4;
				   define newmean   /display width=4;
				   define newmedian /display width=4;
				   define newmax    /display width=4;
				   define newmin    /display width=4;
				   define newrange  /display width=4;
				   define newstddev /display width=4;
				   define oldn      /display width=4;
				   define oldnmiss  /display width=4;
				   define oldmean   /display width=4;
				   define oldmedian /display width=4;
				   define oldmax    /display width=4;
				   define oldmin    /display width=4;
				   define oldrange  /display width=4;
				   define oldstddev /display width=4;	
				   
				   define pctn        /display width=4;
				   define pctnmiss    /display width=4;
				   define pctmean     /display width=4;
				   define pctmedian   /display width=4;
				   define pctmax      /display width=4;
				   define pctmin      /display width=4;
				   define pctrange    /display width=4;
				   define pctstddev   /display width=4;
				   define deltan      /display width=4;
				   define deltanmiss  /display width=4;
				   define deltamean   /display width=4;
				   define deltamedian /display width=4;
				   define deltamax    /display width=4;
				   define deltamin    /display width=4;
				   define deltarange  /display width=4;
				   define deltastddev /display width=4;
				   
				   define pctncat        /display width=10;
				   define pctnmisscat    /display width=10;
				   define pctmeancat     /display width=10;
				   define pctmediancat   /display width=10;
				   define pctmaxcat      /display width=10;
				   define pctmincat      /display width=10;
				   define pctrangecat    /display width=10;
				   define pctstddevcat   /display width=10;
				   define deltancat      /display width=6;
				   define deltanmisscat  /display width=6;
				   define deltameancat   /display width=6;
				   define deltamediancat /display width=6;
				   define deltamaxcat    /display width=6;
				   define deltamincat    /display width=6;
				   define deltarangecat  /display width=6;
				   define deltastddevcat /display width=6;
				   
				   define innew   /display width=4 style(column)=[textalign=center];
				   define inold   /display width=4 style(column)=[textalign=center];
                 run;	
  
           proc datasets lib=work noprint; delete mymnum; run;
  /*========= Now output the contents and categorical dataset using the xlsx libname engine.
   * We cant control headers, filters, or lock panes, but at least this doesn't run out of memory.
   */
  libname xloutlib xlsx "&outpath\ddiff&OUTSUFFIX..xlsx" ;

  
  %memavail(%str(before diffcat));

  *===CATEGORICALS TAB;

  
  %if &LIMITMEM<=2
      %then %do; ods excel options(sheet_name="ChgCatValues"
                    autofilter = "1-15"
				    frozen_rowheaders = "1"
				    row_heights = "42"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcat&OUTSUFFIX split='~' style(header)=[textalign=left verticalalign=top]; 
				   column stdynamS actvstdyfl dsname varname critvarfl inCTfl &UNIQBVLSTF percentage pctcat delta deltacat oldcount newcount cvalstat catval;
				   define stdynamS   /display flow width=10;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   &DEFBYVARS4F;
				   define critvarfl  /display width=4 style(column)=[textalign=center];
				   define inCTFL     /display width=4 style(column)=[textalign=center];
				   define pctcat     /display width=10;
				   define deltacat   /display width=6;
				   define percentage /display width=4;
				   define delta      /display width=4;
				   define oldcount   /display width=4;
				   define newcount   /display width=4;
				   define cvalstat   /display width=4;
				   define catval     /display flow width=40 style(column)=[asis=on];
                 run;				 
	  			 %end;
					    
		   
		      *===Numerics TAB;
  
  %if &LIMITMEM<=1
      %then %do; ods excel options(sheet_name="ChgNumValues"
                                   autofilter = "1-61"
                                   frozen_rowheaders = "1"
                                   row_heights = "28"
                                   frozen_headers = "on");             
                 proc report data=_inlib.ddiffnum&OUTSUFFIX split='~' style(header)=[textalign=left verticalalign=top]; 
                   column &NUMCOLORD;
                   define stdynamS   /display flow width=10;
                   define actvstdyfl /display width=4 style(column)=[textalign=center];
                   define dsname     /display flow width=25;
                   define varname    /display flow width=10;
                   define label      /display flow width=10;
                   &DEFBYVARS4M;
                   define critvarfl  /display width=4 style(column)=[textalign=center];
                   define mvalstat   /display width=4;
                   
                   define newn      /display width=4;
                   define newnmiss  /display width=4;
                   define newmean   /display width=4;
                   define newmedian /display width=4;
                   define newmax    /display width=4;
                   define newmin    /display width=4;
                   define newrange  /display width=4;
                   define newstddev /display width=4;
                   define oldn      /display width=4;
                   define oldnmiss  /display width=4;
                   define oldmean   /display width=4;
                   define oldmedian /display width=4;
                   define oldmax    /display width=4;
                   define oldmin    /display width=4;
                   define oldrange  /display width=4;
                   define oldstddev /display width=4;    
                   
                   define pctn        /display width=4;
                   define pctnmiss    /display width=4;
                   define pctmean     /display width=4;
                   define pctmedian   /display width=4;
                   define pctmax      /display width=4;
                   define pctmin      /display width=4;
                   define pctrange    /display width=4;
                   define pctstddev   /display width=4;
                   define deltan      /display width=4;
                   define deltanmiss  /display width=4;
                   define deltamean   /display width=4;
                   define deltamedian /display width=4;
                   define deltamax    /display width=4;
                   define deltamin    /display width=4;
                   define deltarange  /display width=4;
                   define deltastddev /display width=4;
                   
                   define pctncat        /display width=10;
                   define pctnmisscat    /display width=10;
                   define pctmeancat     /display width=10;
                   define pctmediancat   /display width=10;
                   define pctmaxcat      /display width=10;
                   define pctmincat      /display width=10;
                   define pctrangecat    /display width=10;
                   define pctstddevcat   /display width=10;
                   define deltancat      /display width=6;
                   define deltanmisscat  /display width=6;
                   define deltameancat   /display width=6;
                   define deltamediancat /display width=6;
                   define deltamaxcat    /display width=6;
                   define deltamincat    /display width=6;
                   define deltarangecat  /display width=6;
                   define deltastddevcat /display width=6;
                   
                   define innew   /display width=4 style(column)=[textalign=center];
                   define inold   /display width=4 style(column)=[textalign=center];
                 run;  			 
				 %end;  

   
  *===CONTENTS TAB;
  
    %if &LIMITMEM=0 
      %then %do; ods excel options(sheet_name="AllContents"
                    autofilter = "1-11"
				    frozen_rowheaders = "1"
				    row_heights = "28"
                    frozen_headers = "on");			 
				 proc report data=_inlib.ddiffcont&OUTSUFFIX split='~' style(header)=[textalign=left verticalalign=top]; 
                   column stdynamS actvstdyfl dsname varname inold innew newtypec newlength newlabel newformat newinfmt;
				   define actvstdyfl /display width=4 style(column)=[textalign=center];
				   define inold      /display width=4 style(column)=[textalign=center];
				   define innew      /display width=4 style(column)=[textalign=center];
				   define stdynamS   /display flow width=10;
				   define dsname     /display flow width=25;
				   define varname    /display flow width=10;
				   define newlength  /display width=4 ;
				   define newlabel   /display width=40 style(column)=[asis=on];
				   define newtypec   /display width=4;
				   define newinfmt   /display width=10 flow;
				   define newformat  /display width=10 flow;
                 run;
				 %end;

  
  ods excel close;

   %if &LIMITMEM>2
      %then %do; data xloutlib.ChgCatValues;
				   set _inlib.ddiffcat&OUTSUFFIX(keep=stdynamS actvstdyfl dsname byvars &UNIQBVLSTF varname critvarfl inCTfl percentage pctcat delta deltacat oldcount newcount cvalstat catval) end=eof;
                 run;
				 %end;
   %if &LIMITMEM>1  
      %then %do; data xloutlib.ChgNumValues  ;
	               retain &NUMCOLORD;
                   set _inlib.ddiffnum&OUTSUFFIX;
                 run;
				 %end;
    %if &LIMITMEM>0 
      %then %do; data xloutlib.AllContents;
				   set _inlib.ddiffcont&OUTSUFFIX(keep=stdynamS actvstdyfl dsname varname varcat inold innew oldmodate newmodate chtypfl chlenfl  chlabfl  chfmtfl chinffl 
				                             oldtype newtype oldtypec newtypec oldlength newlength oldlabel newlabel oldformat newformat oldinfmt newinfmt);
                 run;  
				 %end;

%mend mcr_isafe_value_checker_ss;

%memavail(%str(after macro ran));