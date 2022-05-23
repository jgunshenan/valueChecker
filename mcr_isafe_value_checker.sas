/*--------------------------- Seattle Genetics Standard Program Header ---------------------------
|         Program Name: O:\Projects\iSAFE\utilities\autocall\mcr_isafe_value_checker
|         Program Name: O:\Projects\iSAFE\utilities\autocall\mcr_isafe_value_checker
|  Operating System(s): Windows Server 2012
|          SAS Version: 9.4
|               Author: jpg
|              Purpose: Compare raw data delivery to last month's data and summarize differences.

|  Inputs Path\Name(s): 
|                       
| Outputs Path\Name(s): 
|                       
| Macro Parameters: 
|                       
|  Mod. Date   User Name      Modification
| 04MAR2022    jpg            Initial check-in.  Works, but datasets produced are stupidly large.
| 08MAR2022    jpg            Refactor from prod/dev to new/old.  Add cover
| 09MAR2022    jpg            Add percentage and delta filters to alldcat
| 10MAR2022    jpg            Add Active Study filters to alldcat.
| 11MAR2022    jpg            Store freqout on disk. Only rebuild if necessary.
| 14MAR2022    jpg            Add UrgentCat tab.  Add active flag to tabs.  
|                             refactor stdynamf (file-system dir name) vs stdynams (sas-legal name)
| 15MAR2022    jpg            Add Numeric tab
| 16MAR2022    jpg            Add Urgent Numeric and Missing Categorical tabs.  
|                             Make lookups arguments to the macro and visible in the cover tab.
| 17MAR2022    jpg            Add byvars to proc freq and proc means runs
| 28MAR2022    jpg            Armor against missing BYVARS per Lookup Table
| 30MAR2022    jpg            Eliminate DOEXEC
|                             Fix duplicate stdynamS bug
| 06APR2022    jpg            Fix byvars bugs.
|                             added diff column to MissingCat tab
| 13APR2022    jpg            Fix bugs.  Load Controlled Terminology.
| 14APR2022    jpg            Added units to numeric byvars that have units.  Add inCTfl.
| 15APR2022    jpg            fix ^MISSING and nmissing in numerics.  Refined spreadsheets.
| 10MAY2022    jpg            handle new degenerative cases that appear this month for the first time.
|                             minimize str len needs to cope gracefully with empty datasets.
|                             Byvars disappeared in UrgentCat tab.
| 21May2022    jpg            Bug fixes.  Byvars fixed, missing dataset dates fixed.  Cosmetic changes to 
|                             spreadsheet per Randall's requests.
|
| TODO: - dates, visits, by-pattern folders & instances, launch subject-level query.
|       - Automate subject-level query for high-interest issues?
|       - Maybe change freq & range execs to do multiple vars in a single call.  Might be faster.  Fewer datasets.
|       - In calling buildfreq and buildrange, we re-run both new and old if either is out of date.  re-factor
|         to only run what we need to.
|       - ERROR: A lock is not available for WORK._NEWCONT.DATA.
|         This happens on prod.  Need to stop re-using datasets here too...
|       - implement non-missing flag in critvars LUT
|       - print removed byvars to listing.  Not DEBUG
|       - Add program file date to dDsets tab
|       - Fix spreadsheet style, align headers top, turn on filters, bold headers.
|       - missingnum tab counts are wrong
|       - show dates when only one dataset exists
missing catvals are always in CT?
validate catvals output.  separate qc prog do the merge and see if we really have 10K matches and 50K mismatches
|       
|------------------------------------------------------------------------------------------------*/

/* Objective: Summarize differences between 2 iSafe runs, where a run includes approx 100 studies.
 * iSafe typically does a new run every month, with the latest data.  The purpose of this tool is to compare
 * 2 such runs, typically this month and last month, and check for unexpected differences.
 * The macro scans the disk for all studies in the new and old run.  It scans each study for datasets.
 * It runs proc contents on each dataset, and categorizes the variables into categoricals, numerics, and others.
 * It runs proc freq on the categoricals, and proc means on the numerics, and compares the new vs old results.
 *
 * In order to produce meaningful comparisons, we have to get the BY variables right.  For example, if we're
 * looking at a categorical variable in lab data, we need to view each lab test separately in order for
 * our comparison of frequencies to be meaningful.  Looking at a numerics, we have to view each UNITS value separately, 
 * in order for our comparison of means to be meaningful.  A lot of the complexity in this program is about getting
 * those BY variables right.  We specify the BY variables in the Critical Values Lookup Table.
 *
 * This program does something SAS programmers might find unusual.  We build a freq dataset and a means dataset that 
 * each combine info from all datasets in about 100 studies, keeping the necessary BY variables straight.
 *
 * We run proc contents on each dataset to get the variables.  We merge in critvars to get the BY variables.
 * We use those BY variables when running proc freq or proc means.  When we combine the studies into
 * a run, we combine those freq outputs, and those means outputs, along with their BY variables.
 *
 * BY vars are tricky.  First, we get the BY variables for each variable from the CritVars LUT merged into proc cont 
 * from each dataset.  Then we check to make sure those byvars exist in the dataset.  We remove any nonexistent byvars
 * from each byvars list.  We figure out the BY variables we need to use for each dataset's categorical and numeric 
 * outputs.  We store those BY variables with the dataset in an extended attribute called ddiffbyvars.  When we combine
 * the datasets for use in aggregated spreadsheet tables, we also combine the BY variables.  Otherwise, those aggregate
 * spreadsheet tables will be meaningless.
 * 
 */




/* We have 3 macros here:
 * list_files scans the disk and gets a list of the files we need to scan.
 * mcr_isafe_value_checker Top level macro.  Scans disk for studies, then loops through all the 
 *                         studies, calling diff1study on each.  Outputs 2 datasets that
 *                         mcr_isafe_value_checker_ss converts into a spreadsheet.
 * %diff1study Compares one study, new and old datasets.  It calls proc freq on each categorical 
 *             variable, and compares the values in the new and old studies.
 * %buildfreqout rebuilds the freqout dataset if it's not up-to-date on disk.  Loads from disk if it is up to date.
 * %buildmeansout rebuilds the meansout dataset if it's not up-to-date on disk.  Loads from disk if it is up to date.
 *
 */
 
 /*
 * The %mcr_isafe_value_checker top level algorithm:
 *  0) Create libname for _outlib, were all output datasets will go
 *  1) Create dataset for Cover tab in output spreadsheet.  Cover tab includes info about the rest of the spreadsheet.
 *  2) Scan the disk to find the studies under OLD and NEW.
 *     - scan dirs for all files
 *     - filter out non-studies and non-datasets
 *  3) Build allstudies dataset, containing all studies in new or old dirs.
 *     - Studies have 2 names, the file system folder (stdynamF) and a SAS-legal version of same (stdynamS).
 *  4) Flag Active Studies using Active Studies Lookup Table.
 *     - All active studies should appear in allstudies dataset.  Print any orphans to the listing.  Should be none.
 *  5) Add POOLED study to allstudies  File system scan doesn't pick this one up because its one dir level higher than the others.
 *  6) For each study, build an FRUNx and a SRUNx macro variable, where x increments from one.  We will use these later when were
 *     need the File System or SAS names for each study.  LASTSTUDY macro value captures max value of x.
 *  7) Create empty datasets to which our main loop will append.  
 *     - alldcat is all categorical values, contains proc freq output
 *     - allnum is all numeric values, contains proc means output
 *     - allcont is all proc contents output.  This contains info on all the variables.
 *     - alldsets lists all the datasets in all the studies, with info on each.
 *  8) The main loop runs from IFROM (default=1) to ITO (default=LASTSTUDY)
 *     - call %diff1study
 *     - append results to alldcat, allnum, allcont, and alldsets.
 *  9) Categorize values in alldcat for ease of filtering in output spreadsheet.
 * 10) Flag active studies in alldcat, allnum, allcont, and alldsets datasets, based on Active Study Spreadsheet
 * 11) Create small contents datasets in support of output spreadsheet tabs.
 *     - changes in lengty, type, label, format, or informat
 * 12) Output datasets.  Note these can have optional OUTSUFFIX
 *     - ddifcat    Categorical variables that changed between OLD and NEW
 *     - ddiffmcat  Missing Categorical variables 
 *     - ddifnum    Numeric variable variables that changed between OLD and NEW
 *     - ddiffmnum  Missing Categorical variables
 *     - ddiffurgc  Urgent Categoricals, Critical variables on Active Studies
 *     - ddiffurgn  Urgent Numerics, Critical variables on Active Studies
 *     - ddiffcont  Proc contents output on all variables
 *     - ddiffdsets All datasets found in the New and old runs.
 *     - ddiffstdys All studies found in the New and old runs.
 * 13) Add info to contents dataset that we didnt have before.
 * 
 *
 * The %diff1study algorithm:
 *  1) Get the list of files in the study dir
 *  2) Scan the list of files for SAS datasets (.sas7bdat)
 *  3) Build studydsets dataset.
 *  4) Run proc contents on each dataset, building studycont dataset.
 *  5) Flag critical variables using Critical variables Spreadsheet from lookups
 *  6) Categorize variables into Categorical (on which we run proc freq), Numeric (on which we run proc means), and others, on which this tool doesnt compare new and old.
 *  7) Get last modified date from the datasets, so we can tell if the intermediate ddiff datasets need to be re-built.
 *  8) via libname with DLCREATEDIR, make sure the directories exist for the studies, new and old.
 *  9) Check if the existing intermediate datasets (freq and means output) are up to date.  If not, rebuild them via %buildfrequout and %buildmeansout
 * 10) Categorize changes by quantitative change and percentage change, for use in filtering in output spreadsheet.
 * 11) combine old and new means and freq datasets into studymeansout and studyfreqout
 *     - BY variables add complexity.  Need to properly consider appropriate BY variables for each variable.
 * 12) Flag the categorical variables that changed between NEW and OLD runs.
 * 
 *
 * The %buildfrequout algorithm:
 *  1) Create empty result datasets to which we will append.
 *  2) Run proc freq on each categorical value, appending to those result datasets.
 *     - BY variables add complexity.  Need to properly consider appropriate BY variables for each variable.
 *     - We start with large catval length, because we dont know how big it will be.  Then we shrink it once we know the max length.
 *  3) Output intermediate datasets.
 * 
 *
 * The %buildmeansout algorithm:
 *  1) Create empty result datasets to which we will append.
 *  2) Run proc freq on each categorical value, appending to those result datasets.
 *     - BY variables add complexity.  Need to properly consider appropriate BY variables for each variable.
 */
 

%global BYVARS4F BYVARS4M;
 
*======================================================================================================
*====== MACRO TO GET FILES IN A DIR, AND INFO ABOUT THOSE FILES;
* Build dataset containing a list of the files in a data dir, with sizes and last modified dates.
* Ignore iSafe dirs like history, testing, and pgms.
* If the last modified date and size values are missing, this means its either a directory or a file we cant open.
* This macro does not look in subdirectories.;
%macro list_files(dir,dsnam);

  *** Open the dir;
  %local filrf rc did memcnt name i;
  %let rc=%sysfunc(filename(filrf,&dir));
  %let did=%sysfunc(dopen(&filrf));   

   %if if rc=0 or &did eq 0 %then %do; 
    /*put WARNING: Directory &dir cannot be opened or does not exist;
	 * dont warn.  new dirs appear in new and not old.  this is normal.
	 */
	data &dsnam;
      length fname $100 fpath $500 ;
	  call missing(fname, fpath);
	stop; run;
    %return;
  %end;
  
  *** Build a dataset containing the files in the dir;
  data &dsnam;
    length fname $100 fpath $500;
    %do i = 1 %to %sysfunc(dnum(&did));   
      fname="%qsysfunc(dread(&did,&i))";
	  fname=strip(fname);
	  fpath = cats("&dir.\", fname);
	  fnlen = length(fname);
      output;
      %end;
  run;
  %let rc=%sysfunc(dclose(&did)); 
  %let rc=%sysfunc(filename(filrf));
%mend list_files;
*========== END FILE MACRO;




*========================================================================================;
*========== DDIFF MACRO.  COMPARES 2 ISAFE RUNS AND DOCUMENTS SELECTED DIFFERENCES;

%macro mcr_isafe_value_checker
   (OLDRDIR=,                                                                                           /* Old Run Dir */
    NEWRDIR=,                                                                                           /* New Run Dir */
	IDSPATH=,                                                                                           /* Intermediate Datasets, freqout and meansout */
	OUTPATH=%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived\testing\freqout), /* Output datasets.  ddiff*.sas7bdat */
	OUTSUFFIX=,                                                                                         /* Output Suffix */
	CRITVARSS=%str(O:\Projects\iSAFE\utilities\lookups\lu_isafe_critical_reporting_var_list.xlsx),      /* Critical Variables Lookup table */
	MDDTSS=%str(O:\Projects\iSAFE\utilities\mddt\mddt_isafe.xlsx),                                      /* MDDT Spreadsheet */
	RUNPOOLED=Y,                                                                                        /* Include POOLED in this run */
	ACTVSTDYLUT=l.lu_isafe_cpyraw,                                                                      /* Active Study Lookup table */
	debug=N,                                                                                            /* Debugging flag, turns on proc prints */
	ALWAYSBUILD=N,                                                                                      /* Debugging flag, always rebuild intermediate datasets */
	IFROM=,                                                                                             /* Debugging flag, start I in main loop. I must exist */
	ITO=                                                                                                /* Debugging flag, end I in main loop. I must exist  */
	);
						  
  %put in mcr_isafe_value_checker 2;
  %let WARNONCE_A=0;
  
  %if %length(&IDSPATH)=0 %then %do; %put ERROR: mcr_isafe_value_checker required argument IDSPATH Missing.  Aborting...;
                                     %abort;
									 %end;
  
  * Dont automatically create this.  It should pre-exist.  Abort if not;
  data _null_;
    length msg $200;
    rc=libname("_outlib", "&OUTPATH"); 
	if rc ne 0 then do; msg="&sysmsg";
	                    putlog "ERR" "OR: Cant open &OUTPATH.  " msg;
	                    abort;
						end;
  run;

  
  *======== Fill in what we know of the cover tab dataset;
  data coverdset (label='Cover Dsets');
	length name $50 value $200;
	ord=0; name="About This Workbook:";        value="Value Differences Between Old and New iSafe Runs";         output;
	ord=1; name="NEWRDIR: New Run Directory:"; value="&NEWRDIR\data\derived\*";                                  output;
	ord=2; name="OLDRDIR: Old Run Directory:"; value="&OLDRDIR\data\derived\*";                                  output;
	ord=4; name="Time of Data Scan Start:";    value=put(datetime(),datetime.);                                  output;
	/* FOR LINUX name="  Host:";               value=sysget('HOST');                                             output; */
	                                           value=sysget('COMPUTERNAME');
	if value="SGSASV1" then                    value="Production (SGSASV1)";
    if value="SGSASV1-STG" then                value="Staging (SGSASV1-STG)";
	ord=6; name="Server:";                                                                                        output;
	ord=7; name="Time of Spreadsheet Build Start:";                                                               output;
	ord=30; name="";                    value="";                                                                 output;
	ord=31; name="About the Tabs:";     value="(Missing tabs have no content.)";                                  output;
	ord=32; name="  Studies Tab:";      value="List Studies Found, and which are Active";                         output;
	ord=33; name="  dDsets Tab:";       value="Change (delta) in Datasets";                                       output;
	ord=34; name="  dType Tab:";        value="All Vars that differ in type between Old and New";                 output;
    ord=35; name="  dLength Tab:";      value="All Vars that differ in length between Old and New";               output;
    ord=36; name="  dLabel Tab:";       value="All Vars that differ in label between Old and New";                output;
    ord=37; name="  dFormat Tab:";      value="All Vars that differ in format between Old and New";               output;
    ord=38; name="  dInfmt Tab:";       value="All Vars that differ in infmt between Old and New";                output;
	ord=40; name="  MissingCat Tab:";   value="Missing Categorical Values";                                       output;
	ord=41; name="  MissingNum Tab:";   value="Missing Numeric Values";                                           output;
	ord=42; name="  UrgentCat Tab:";    value="Urgent Changes in Categorical Values";                             output;
	ord=43; name="  UrgentNum Tab:";    value="Urgent Changes in Numeric Values";                                 output;
	ord=44; name="  ChgCatValues Tab:"; value="Changes in Categorical Values. (Comparison of proc freq outputs)"; output;
	ord=45; name="  ChgNumValues Tab:"; value="Changes in n/Mean/Median/Min/Max/StD/Range in Numeric Variables. (Via proc means)"; output;
 	ord=46; name="  AllContents Tab:";  value="Proc Contents Outputs From All Datasets in both New and Old";          output;
	ord=50; name="";                        value="";                                                                 output;
	ord=51; name="Notes:";                  value="";                                                                 output;
	ord=52; name="  d prefix in tab name:"; value="delta, i.e. change in";                                            output;
	ord=53; name="  ChgCatValues:";         value="Excludes variables whose counts for each category did not change"; output;
	ord=53; name="  ChgNumValues:";         value="Excludes variables whose Mean and StD did not change";             output;
	ord=54; name="  Urgent:";               value="Includes only Critical Variables in Active Studies";               output;
    ord=70; name="";                                           value="";                                              output;
	ord=71; name="References:";                                value="";                                              output;
	ord=72; name="  CRITVARSS: Critical Values Spreadsheet:";  value="&CRITVARSS";                                    output;
	ord=73; name="  MDDT Spreadsheet (Controlled Terms):";     value="&MDDTSS";                                       output;
	ord=74; name="  Active Study Lookup Table:";               value="&ACTVSTDYLUT";                                  output;
	ord=75; name="  User:";                                    value="&SYSUSERID";                                    output;
	ord=76; name="  SAS Program File:";                        value="&sasprogramfile";                               output;
	ord=77; name="  OUTPATH: SAS Output Written To:";          value="&OUTPATH";                                      output;
	ord=78; name="  IDSPATH: SAS Intermediate Freq & Means Output Written To:"; value="&IDSPATH";                     output;
	ord=79; name="  Spreadsheet Input Read From:";             value="";                                              output;
	ord=80; name="  Spreadsheet Output Written To:";           value="";                                              output;
	ord=94; if "&RUNPOOLED" ne "N"      then do; name="  RUNPOOLED (include POOLED in this run):"; value="&RUNPOOLED";output; end;
	ord=95; if ^missing("&IFROM")       then do; name="  IFROM (skip studies before i):";          value="&IFROM";    output; end;
	ord=96; if ^missing("&ITO")         then do; name="  ITO (skip studies after i):";             value="&ITO";      output; end;
	ord=97; if "&DEBUG" ne "N"          then do; name="  DEBUG: (Controls listing output)";        value="&DEBUG";    output; end;
	ord=98; if ^missing("&OUTSUFFIX")   then do; name="  OUTSUFFIX:";                              value="&OUTSUFFIX";output; end;
	ord=99; if "ALWAYSBUILD" ne "N"     then do; name="  ALWAYSBUILD: (rebuild intermediate dsets)";value="&ALWAYSBUILD";output; end;
  run;

 
  *======= Get the list of studies in the old dir.  ;
  %list_files(&OLDRDIR\data\derived\, olditems);
  data olditems;
    set olditems;
  run;
  data oldstudies;
    set olditems;
	fnamelen = length(fname);
	if index(fname, ".sas7bdat")= fnamelen-8 then delete;
	if index(fname, ".lnk")= fnamelen-3      then delete;
	if index(fname, ".lck")= fnamelen-3      then delete;
	if index(fname, ".csv")= fnamelen-3      then delete;
	if index(fname, ".bak")= fnamelen-3      then delete;
	if index(fname, ".xls")= fnamelen-3      then delete;
	if index(fname, ".xlsx")= fnamelen-4     then delete;
	if fname in ('testing' 'history' 'pgms') then delete;  
  run;

  
  *======= Get the list of Studies in the new dir;
  %list_files(&NEWRDIR\data\derived\, newitems);
  data newstudies;
    set newitems;
	fnamelen = length(fname);
	if index(fname, ".sas7bdat")= fnamelen-8 then delete;
	if index(fname, ".lnk")= fnamelen-3      then delete;
	if index(fname, ".lck")= fnamelen-3      then delete;
	if index(fname, ".csv")= fnamelen-3      then delete;
	if index(fname, ".bak")= fnamelen-3      then delete;
	if index(fname, ".xls")= fnamelen-3      then delete;
	if index(fname, ".xlsx")= fnamelen-4     then delete;
	if index(fname, "&")= 1                  then delete;
    if fname in ('testing' 'history' 'pgms') then delete;  
  run;
  
  proc sort data=oldstudies; by fname; run;
  proc sort data=newstudies;  by fname; run;

  data allstudies;
    merge oldstudies(in=_inold) newstudies(in=_innew);
	by fname;
	inold=_inold;
	innew=_innew;
	keep fname innew inold;
  run;
  
  *========== Read in and Flag Active Studies; 
   
  data allstudies;
    set allstudies;
	length stdynamf StdynamS $50;
	label stdynamF="File System Study Name"
	      stdynamS="SAS-legal Study Name";
	stdynamF=fname;
	stdynamS=lowcase(tranwrd(fname, "-", "_"));
  run;
  
  data myactive;
    set l.lu_isafe_cpyraw;
	length stdynamS $50;
    stdynamS=lowcase(tranwrd(study, "-", "_"));
	if (raw_data_source__or_locked_='Extract from DM' or (raw_data_source__or_locked_='Locked' and temp_status='Lock Override')) 
       and in_production='Y' and monthly_SD='Y';
	keep stdynamS raw_data_source__or_locked_ temp_status in_production monthly_SD;
  run;
  
  proc sort data=myactive; by stdynamS; run;
  proc sort data=allstudies; by stdynamS; run;
  
  data allstudies activeorphans;
    merge allstudies(in=_instdys) myactive(in=_inmyactive);
	by stdynamS;
	label actvstdyfl= "Active Study Flag";
    inmyactive=_inmyactive;
	if _inmyactive
	  then actvstdyfl=1;
	  else actvstdyfl=0;
	if _instdys then output allstudies;
	            else output activeorphans;
  run;
  
  proc sort data=allstudies; by stdynamS actvstdyfl; run;
  data allstudies ;
    set allstudies;
	by stdynamS actvstdyfl;
	if last.actvstdyfl;
  run;
  
  %if &DEBUG=Y %then %do; title allstudies.fname merged with l.lu_isafe_cpyraw.study;
                         proc print data=allstudies; 
                           var stdynamS actvstdyfl inold innew inmyactive In_Production ;
                         run;
                         
						 title cpyraw Active Studies that Do Not Appear in the iSafe directories;
						 proc print data=activeorphans; 
                         run;
						 title;
						 %end;
  data allstudies;
    set allstudies;
	drop raw_data_source__or_locked_ temp_status in_production monthly_SD;
  run;
  
  %if &RUNPOOLED=Y %then %do; data allstudies;
                                set allstudies end=eof;
	                            output;
	                            if eof then do; fname="POOLED";
	                                            stdynamS="POOLED";
					                            stdynamF="POOLED";
					                            innew=1;
					                            inold=1;
					                            actvstdyfl=1;
	                                            fnamelen = length(fname);
	                                            output;
	                                            end;
                              run;
                              %end;
  
  /* OK.  A RUN is a single run of a single study.  
   * Each run typically appears both in the old and new dir.
   * We have 2 forms of RUN ID, the File system ID, &&FRUN&I, which is the directory name,
   * and the SAS-legal ID, &&SRUN&I, which contains only SAS-legal characters.  We use
   * the former to construct file system paths, and the latter to construct SAS things like 
   * libnames and variables.
   *
   * This complexity would all go away if people stopped the deeply evil practice of using 
   * hyphens in file and directory names.
   *
   * We dont have a RUN to analyze unless we have both new and old, so we only create FRUN
   * and SRUN and increment the icounter if we have both.
   */
   data allstudies;
    set allstudies end=eof;
	length fsymnam ssymnam $100;
	retain icounter 0;
	
	if innew and inold
       then do; icounter=icounter+1;
	            fsymnam=cats("FRUN",(vvalue(icounter)));
	            call symput(fsymnam, strip(stdynamF));
	
	            ssymnam=cats("SRUN",(vvalue(icounter)));
	            call symput(ssymnam, strip(stdynamS));
				%if &DEBUG=Y %then %do; putlog "stdynamS: " stdynamS " stdynamF: " stdynamF " icounter: " icounter; %end;
	            end;
	if eof then call symput("LASTSTUDY", strip(vvalue(icounter)));
   run;
   
  %if &DEBUG=Y
      %then %do; title "oldstudies. OLDRDIR: &OLDRDIR\data\derived\";
                 proc print data=oldstudies; run;

                 title "allstudies.  NEWRDIR: &NEWRDIR\data\derived\";
                 proc print data=allstudies; var fname stdynamF stdynamS innew inold; run;
                 title;
				 %end;
				 
				 
      *========== Get Controlled Terms from MDDT Spreadsheet;
  libname mddtss xlsx "&MDDTSS" access=READONLY;

  data cdiscct;    
    set mddtss.'CDISC CT'n(keep=Code Codelist_Code Extensible Codelist_Name Submission_Value Synonyms Definition 
                                Std_CRF_Coded_Value Std_CRF_Decode CRF_Coded_Value CRF_Decode Active);
	if _error_ then abort;
  run;
  
  data customct;   
    set mddtss.'Custom CT'n(keep=lbcat Codelist_Code  Extensible Codelist_Name Submission_Value Synonyms Definition 
                                Std_CRF_Coded_Value Std_CRF_Decode CRF_Coded_Value CRF_Decode Active);
	if _error_ then abort;
  run;

  data externalct; 
    set mddtss.'External CT'n(keep=Name Description Dictionary Version Ref Href);
  run;
   
  data CTlist;
    length submission_value $200;
    set cdiscct(in=_cdisc keep=Submission_Value Codelist_Name) customct(in=_cust keep=Submission_Value Codelist_Name);
	length CTSRC $6;
	if _cdisc then CTSRC="CDISC";
	if _cust  then CTSRC="CUSTOM";
  run; 
  
  proc sort data=CTlist; by Submission_Value Codelist_Name; run;
  
  data CTlist;
    set CTlist;
	by Submission_Value Codelist_Name;
	length codelists $200;
	retain codelists incdisc incustom;
	if first.submission_value then do; codelists=''; incdisc=0; incustom=0; end;
	if CTSRC="CDISC" then incdisc=1;	
	if CTSRC="CUSTOM" then incustom=1;
    if codelist_name ne codelists then
	   codelists=catx(', ', codelists, codelist_name);
	if last.submission_value then do; if incdisc and incustom then CTSRC="BOTH";
	                                  output;
									  end;
    keep submission_value codelists CTSRC;
  run;
  
  

   *========== get critical variables;
  libname lookupss xlsx "&CRITVARSS" access=READONLY;

  data critvars;
  length _variable $32;
    set lookupss.TLF_Critical_Variables;
  run;
 
  *TESTKEY byvar means lbcat lbtestcd; 
  data critvars; 
    set critvars(rename=(_variable=varname)); 
	length byvars $100;
	format varname;
    if upcase(byvar)="TESTKEY"
       then do; if      lowcase(varname) ^in ('lbcat' 'lbtestcd')
	                    then byvars="lbcat lbtestcd testkey";
				else if lowcase(varname) = 'lbcat'
				        then byvars="lbtestcd testkey";
				else if lowcase(varname) = 'lbtestcd'
				        then byvars="lbcat testkey";
			    end;
    else if ^missing(byvar)    then byvars=lowcase(BYVAR);
	varname=lowcase(varname);
	drop byvar;
  run;
  
  * Units have to be a byvar if the variable has units;
  data critvars; 
    set critvars; 
	if lowcase(varname) in ( 'cnvrsn'  'cnvlo'  'cnvhi') and index(byvars, "cnvu")=0          then byvars=catx(' ', byvars, 'cnvu');
	if lowcase(varname) in ('scnvrsn' 'scnvlo' 'scnvhi') and index(byvars, "cnvu")=0          then byvars=catx(' ', byvars, 'cnvu');
	if lowcase(varname) in (  'sirsn'   'silo'   'sihi') and index(byvars, "siu")=0           then byvars=catx(' ', byvars, 'siu');
	if lowcase(varname) in ('pcstresn' 'pclloq' 'pculoq')and index(byvars, "pcstresu")=0      then byvars=catx(' ', byvars, 'pcstresu');
	if lowcase(varname) in ('vsstresn')                  and index(byvars, "vsstresu")=0      then byvars=catx(' ', byvars, 'vsstresu');
	if lowcase(varname) in ('drug_adm')                  and index(byvars, "drug_admu")=0     then byvars=catx(' ', byvars, 'drug_admu');
	if lowcase(varname) in ('int_dose_reg')              and index(byvars, "int_dose_regu")=0 then byvars=catx(' ', byvars, 'int_dose_regu');
  run;  
  
  
  %if &DEBUG=Y %then %do; title critvars;
                         proc print data=critvars; run;
                         proc contents data=critvars; run;
                         title;
                         %end;
  
  proc sort data=critvars nodupkey; by varname; run;
  
  *===== END CRITVARS;
						  
  *========= Create empty datasets to which we will later concatenate data.  
  *========= Initialize with variables so the code below behaves if datasets remain empty.;
  data alldcat; length stdynamS dsname $50 varname $32 catval $400 cvalstat $4 oldcount newcount count percent difffl 8; 
                 call missing(stdynamS, dsname, varname, catval, count, difffl, cvalstat, oldcount, newcount, percent);  
				 stop; run;  
  data allnum; length stdynamS dsname $50 varname $32 mvalstat $4 label $256 critvarfl 8; 
                 call missing(stdynamS, dsname, varname, mvalstat, label, critvarfl);  
				 stop; run;  
  data allcont;  length stdynamS dsname $50 varname $32 catval $400 count percent oldmodate newmodate 8 newlabel oldlabel $256; 
                 call missing(stdynamS, dsname, varname, catval, count, percent, oldmodate, newmodate, newlabel, oldlabel ); 
				 stop; run;  
  data alldsets; length stdynamS dsname $50 ; 
                 call missing(stdynamS, dsname); 
                 stop; run;   
  data allbyvarsF; length stdynamS dsname byvar $50 varname $32;
                  call missing(stdynamS, dsname, byvar, varname); 
                  stop; run;     
  data allbyvarsM; length stdynamS dsname byvar $50 varname $32;
                  call missing(stdynamS, dsname, byvar, varname); 
                  stop; run;     
  data byvardsF; length stdynamS dsname byvar $50 varname $32;
                  call missing(stdynamS, dsname, byvar, varname); 
                  stop; run;     
  data byvardsM; length stdynamS dsname byvar $50 varname $32;
                  call missing(stdynamS, dsname, byvar, varname); 
                  stop; run;  

  *========== Loop through the studies and compare each.  Concatenate study data to "all" datasets;
  *========== IFROM and ITO are for DEBUGging, to allow control of which studies get run.;
  %if %length(&IFROM)=0 %then %do; %let IFROM=1; %end;
                        %else %do; %PUT WARNING: IFROM set to &IFROM; %end;
  %if %length(&ITO)  =0 %then %do; %let ITO=&LASTSTUDY; %end;
                        %else %do; %PUT WARNING: ITO set to &ITO; %end;
  %if &ITO > &LASTSTUDY %then %do; %PUT ERROR: ITO: &ITO too large.  LASTSTUDY: &LASTSTUDY;
                                   %ABORT ABEND;
								   %end;

  %do i=&IFROM %to &ITO;
      %PUT FRUN&i: &&FRUN&i;
 
	  %diff1study();
	  data allcont;
	    set allcont studycont;
	  run;
	  data alldcat;
	    length catval $400;
	    set alldcat studydcat;
	  run;	  
	  data allnum;
	    set allnum studymeansout;
	  run;
	  data alldsets;
	    set alldsets studydsets;
	  run;	  
	  title alldsets; proc print data=alldsets; run; *jpg;
	  data allbyvarsF;
	    set allbyvarsF byvardsF;
	  run;	  
	  data allbyvarsM;
	    set allbyvarsM byvardsM;
	  run;
	  %end;	

	  
  *===========================;
  proc sort data=alldcat; by catval; run;
  
  data alldcat;
    merge alldcat(in=_incat) CTlist(in=_inct rename=(Submission_Value=catval));
	by catval;
	if _incat;
	if _inct then inCTfl=1;
	         else inCTfl=0;
  run;
	  
  *===========================;	 
  proc sort data=alldsets; by stdynamS dsname; run;
  proc sort data=allcont out=alldscont nodupkey; by stdynamS dsname oldmodate newmodate; run;

	  title alldsets2; proc print data=alldsets; run; *jpg;
title allcont 0; proc print data=allcont; var stdynamS dsname oldmodate newmodate; run;
title alldscont 0; proc print data=alldscont; var stdynamS dsname oldmodate newmodate; run;

  *dscont has multiple obs per dset, some with missing dates.  Compress to one obs per dataset with all dates.;
  data alldscont;
    set alldscont(rename=(oldmodate=_oldmodate newmodate=_newmodate));
	by stdynamS dsname _oldmodate _newmodate;
	retain oldmodate newmodate;
	format oldmodate newmodate datetime.;
	if first.dsname then do; oldmodate=.; newmodate=.; end;
	if ^missing(oldmodate) and oldmodate ne _oldmodate 
	   then putlog "WARN" "ING: unexpected oldmodate change: " _oldmodate " to: " oldmodate;
	if ^missing(newmodate) and newmodate ne _newmodate 
	   then putlog "WARN" "ING: unexpected newmodate change: " _newmodate " to: " newmodate;
	if ^missing(_oldmodate) then oldmodate=_oldmodate;
	if ^missing(_newmodate) then newmodate=_newmodate;
	if last.dsname then output;
	drop _oldmodate _newmodate;
  run;
  
    title alldscont 1; proc print data=alldscont; var stdynamS dsname oldmodate newmodate; run; *jpg;

  
  data alldsets;
    merge alldsets (in=inds) alldscont(keep=stdynamS dsname oldmodate newmodate);
	by  stdynamS dsname;
	format deltamodate 8.;
	if inds;
	label newmodate  = "New Modified Date"
		  oldmodate  = "Old Modified Date"
		  deltamodate= "Change in Modified Date (days)";
	if ^missing(newmodate) and ^missing(oldmodate) 
	   then deltamodate = round((newmodate-oldmodate)/(60*60*24));
  run;
  

	  title alldsets3; proc print data=alldsets; run; *jpg;
  
   *===========================;	  
  
  Title Problem Byvars;
  title2 If the Crit Vars LUT specifies a byvar that is not in the dataset, we drop that byvar for that dataset;
  proc print data=allcont;
    var stdynamS dsname varname byvars origbyvars; 
    where byvars ne origbyvars;
  run;
  title;
  
  /* 
   * allcont is the proc contents output for all variables in all studies.
   * Some of those variables have byvars as attributes, such as byvars="lbcat lbtest"
   * allbyvars lists those byvars one per observation.
   * We merge allbyvars with allcont to get the length and type of each by variable.
   * We capture the type and max length of each byvar, so we can use this in building spreadsheets.
   */
  proc sort data=allbyvarsF; by stdynamS dsname byvar; run;
  proc sort data=allbyvarsM; by stdynamS dsname byvar; run;
  proc sort data=allcont;   by stdynamS dsname varname; run;
  data allbyvarsF;
    merge allbyvarsF(in=inbv keep=stdynamS dsname varname byvar) allcont(rename=(varname=byvar));
	by stdynamS dsname byvar;
	if inbv;
	keep byvar newlength oldlength newtype oldtype;
  run;
  data allbyvarsM;
    merge allbyvarsM(in=inbv keep=stdynamS dsname varname byvar) allcont(rename=(varname=byvar));
	by stdynamS dsname byvar;
	if inbv;
	keep byvar newlength oldlength newtype oldtype;
  run;
  
  proc sort data=allbyvarsF out=uniqbyvarsF; by byvar; run;
  proc sort data=allbyvarsM out=uniqbyvarsM; by byvar; run;

  
  data uniqbyvarsF;
    set uniqbyvarsF;
	by byvar;
	retain bvlen bvtyp;
	if first.byvar then do; bvlen=.; bvtyp=.; end;
	if newlength> bvlen then bvlen=newlength;
	if oldlength> bvlen then bvlen=oldlength;
    if missing(bvtyp) then bvtyp = newtype;
    if missing(bvtyp) then bvtyp = oldtype;
    if (^missing(newtype) and bvtyp ne newtype) or
	   (^missing(oldtype) and bvtyp ne oldtype) 
	   then putlog "WARN" "ING: Type mismatch in byvar: " byvar " bvtyp: " bvtyp " newtype: " newtype " oldtype: " oldtype;
	if last.byvar then output;
  run;
    
  data uniqbyvarsM;
    set uniqbyvarsM;
	by byvar;
	retain bvlen bvtyp;
	if first.byvar then do; bvlen=.; bvtyp=.; end;
	if newlength> bvlen then bvlen=newlength;
	if oldlength> bvlen then bvlen=oldlength;
    if missing(bvtyp) then bvtyp = newtype;
    if missing(bvtyp) then bvtyp = oldtype;
    if (^missing(newtype) and bvtyp ne newtype) or
	   (^missing(oldtype) and bvtyp ne oldtype) 
	   then putlog "WARN" "ING: Type mismatch in byvar: " byvar " bvtyp: " bvtyp " newtype: " newtype " oldtype: " oldtype;
	if last.byvar then output;
  run;
  
  %let WCLAUSE=where lowcase(varname) in ('lbcat' 'lbtestcd' 'testkey');
  title "allcont &WCLAUSE"; proc print data=allcont; &WCLAUSE; run;  
  title allbyvarsF; proc print data=allbyvarsF; run;
  title allbyvarsM; proc print data=allbyvarsM; run;
  title uniqbyvarsF; proc print data=uniqbyvarsF; run;
  title uniqbyvarsM; proc print data=uniqbyvarsM; run;
  title;
  
  %LET UNIQBVLSTF=;
  %LET UNIQBVLENF=;
  %LET UNIQBVMISF=;
  data _null_;
    set uniqbyvarsF end=eof;
	length ubvlst $1000 ubvlen ubvmis $5000;
	retain ubvlst ubvlen ubvmis '';
	if bvtyp=2
	   then ubvlen=catx(' ', ubvlen, byvar, cats("$", vvalue(bvlen)));
	ubvlst=catx(' ', ubvlst, byvar);
	if ^missing(ubvmis) then ubvmis=cats(ubvmis, ",");
	ubvmis=catx(' ', ubvmis, byvar);
	if eof then do; if ^missing(ubvlen) then ubvlen=catx(' ', "length", ubvlen, ";");
	                if ^missing(ubvmis) then ubvmis=cats("missing(", ubvmis, ");");
	                call symput("UNIQBVLSTF", strip(ubvlst));
	                call symput("UNIQBVLENF", strip(ubvlen));
	                call symput("UNIQBVMISF", strip(ubvmis));
					end;
  run;
  %PUT UNIQBVLSTF: &UNIQBVLSTF;
  %PUT UNIQBVLENF: &UNIQBVLENF;
  %PUT UNIQBVMISF: &UNIQBVMISF;
    
  %LET UNIQBVLSTM=;
  %LET UNIQBVLENM=;
  %LET UNIQBVMISM=;
  data _null_;
    set uniqbyvarsM end=eof;
	length ubvlst $1000 ubvlen ubvmis $5000;
	retain ubvlst ubvlen ubvmis '';
	if bvtyp=2
	   then ubvlen=catx(' ', ubvlen, byvar, cats("$", vvalue(bvlen)));
	ubvlst=catx(' ', ubvlst, byvar);
	if ^missing(ubvmis) then ubvmis=cats(ubvmis, ",");
	ubvmis=catx(' ', ubvmis, byvar);
	if eof then do; if ^missing(ubvlen) then ubvlen=catx(' ', "length", ubvlen, ";");
	                if ^missing(ubvmis) then ubvmis=cats("missing(", ubvmis, ");");
	                call symput("UNIQBVLSTM", strip(ubvlst));
	                call symput("UNIQBVLENM", strip(ubvlen));
	                call symput("UNIQBVMISM", strip(ubvmis));
					end;
  run;
  %PUT UNIQBVLSTM: &UNIQBVLSTM;
  %PUT UNIQBVLENM: &UNIQBVLENM;
  %PUT UNIQBVMISM: &UNIQBVMISM;
  
  
  *======  Add percentage and delta categories to alldcat;
  data alldcat;
  set alldcat;
    length pctcat deltacat $12; 
    label pctcat = "Percentage~(newcount/oldcount)"	
	      deltacat = "Delta~(newcount-oldcount)";
	if ^missing(newcount) and ^missing(oldcount)
	   then do;	delta=newcount-oldcount;
	            if      delta<= -100 then deltacat=     "x<=-100";
	            if -100<delta<=  -90 then deltacat="-100<x<=-90";
	            if  -90<delta<=  -80 then deltacat= "-90<x<=-80";
	            if  -80<delta<=  -70 then deltacat= "-80<x<=-70";
	            if  -70<delta<=  -60 then deltacat= "-70<x<=-60";
	            if  -60<delta<=  -50 then deltacat= "-60<x<=-50";
	            if  -50<delta<=  -40 then deltacat= "-50<x<=-40";
	            if  -40<delta<=  -30 then deltacat= "-40<x<=-30";
	            if  -30<delta<=  -20 then deltacat= "-30<x<=-20";
	            if  -20<delta<=  -10 then deltacat= "-20<x<=-10";
	            if  -10<delta<=   -1 then deltacat= "-10<x<=-1";
	            if      delta=    -1 then deltacat=     "x=-1";
	            if      delta=     0 then deltacat=     "x=0";
	            if      delta=     1 then deltacat=     "x=1";
	            if    1<delta<=   10 then deltacat=   "1<x<=10";
	            if   10<delta<=   50 then deltacat=  "10<x<=50";
	            if   50<delta<=  100 then deltacat=  "50<x<=100";
	            if  100<delta        then deltacat= "100<x";				
	
	            if oldcount=0 then percentage=.;
	                          else percentage = round(newcount/oldcount*100, 1);
							  
	            if     percentage<   0 then pctcat=     "x<0%";
	            if     percentage =  0 then pctcat=     "x=0%";
				if   0<percentage<= 10 then pctcat=  "0%<x<=10%";
				if  10<percentage<= 20 then pctcat= "10%<x<=20%";
				if  20<percentage<= 30 then pctcat= "20%<x<=30%";
				if  30<percentage<= 40 then pctcat= "30%<x<=40%";
				if  40<percentage<= 50 then pctcat= "40%<x<=50%";
				if  50<percentage<= 60 then pctcat= "50%<x<=60%";
				if  60<percentage<= 70 then pctcat= "60%<x<=70%";
				if  70<percentage<= 80 then pctcat= "70%<x<=80%";
				if  80<percentage<= 90 then pctcat= "80%<x<=90%";
				if  90<percentage< 100 then pctcat= "90%<x<=100%";
	            if     percentage= 100 then pctcat=     "x=100%";
	            if 100<percentage<=110 then pctcat="100%<x<=110%";
	            if 110<percentage<=120 then pctcat="110%<x<=120%";
	            if 120<percentage<=130 then pctcat="120%<x<=130%";
	            if 130<percentage<=140 then pctcat="130%<x<=140%";
	            if 140<percentage<=150 then pctcat="140%<x<=150%";
	            if 150<percentage<=160 then pctcat="150%<x<=160%";
	            if 160<percentage<=170 then pctcat="160%<x<=170%";
	            if 170<percentage<=180 then pctcat="170%<x<=180%";
	            if 180<percentage<=190 then pctcat="180%<x<=190%";
	            if 190<percentage<=200 then pctcat="190%<x<=200%";
	            if 200<percentage      then pctcat="200%<x";
				end;
  run;
  

  
  *========== Flag Active Studies in alldsets;

  proc sort data=allstudies out=actvstdy nodupkey; by stdynamS actvstdyfl; run;
  proc sort data=alldsets; by stdynamS ; run;
  data alldsets;
    merge alldsets(in=_inalldsets) actvstdy( keep= stdynamS actvstdyfl );
    by stdynamS; 
	if _inalldsets;
  run;
  
    %if &DEBUG=Y
      %then %do; title alldsets actvstdyfl  freq;
                 proc freq data=alldsets; table stdynamS*actvstdyfl/list missing nocum nopercent; run;
                 title;
				 %end;
  
  *========== Flag Active Studies in allnum;
  %macro doround(_var, _sdigits);
  if missing(&_var) then &_var=.;
                    else do; if &_sdigits=0 then &_var=round(&_var);
                                            else &_var=round(&_var, &_sdigits);
							 end;
  %mend;
  
  proc sort data=allnum; by stdynamS; run;
  data allnum;
    merge allnum(in=_inallnum) actvstdy(keep= stdynamS actvstdyfl );
    by stdynamS; 
	if _inallnum;
	format newn oldn deltan pctn pctmean pctmedian pctmax pctmin pctrange pctstddev newnmiss oldnmiss deltanmiss 8.;
	%doround(newn,      0);
	%doround(oldn,      0);
	%doround(deltan,    0); 
	%doround(pctn,      0);
	%doround(pctmean,   0);
	%doround(pctmedian, 0); 
	%doround(pctmax,    0);
	%doround(pctmin,    0);
	%doround(pctrange,  0);
	%doround(pctstddev, 0);
	%doround(newnmiss,  0);
	%doround(oldnmiss,  0);
	%doround(deltanmiss,0);
	format newmean   newmedian   newmax   newmin   newrange
           oldmean   oldmedian   oldmax   oldmin   oldrange
		 deltamean deltamedian deltamax deltamin deltarange 8.1;
	%doround(newmean,     0.1);
	%doround(newmedian,   0.1);
	%doround(newmax,      0.1);
	%doround(newmin,      0.1);
	%doround(newrange,    0.1);
	%doround(oldmean,     0.1);
	%doround(oldmedian,   0.1); 
	%doround(oldmax,      0.1);
	%doround(oldmin,      0.1);
	%doround(oldrange,    0.1);
	%doround(deltamean,   0.1); 
	%doround(deltamedian, 0.1); 
	%doround(deltamax,    0.1);
	%doround(deltarange,  0.1);	
	%doround(deltamin,    0.1);
    format newstddev oldstddev deltastddev 8.2;
	%doround(newstddev,   0.01);
	%doround(oldstddev,   0.01); 
	%doround(deltastddev, 0.01);
  run;  
  
   *========== Flag Active Studies in alldcat;
  proc sort data=alldcat; by stdynamS; run;
  data alldcat;
    merge alldcat(in=_inalldcat) actvstdy(keep= stdynamS actvstdyfl );
    by stdynamS; 
	if _inalldcat;
  run;  
  
  *========== Flag Active Studies in allcont;
  proc sort data=allcont; by stdynamS; run;
  data allcont;
    merge allcont(in=_inallcont) actvstdy(keep= stdynamS actvstdyfl );
    by stdynamS; 
	if _inallcont;
  run;
  
  *======= build small contents change datasets;
  data allcont;
    set allcont;
	label chtypfl = "Chg Typ"
	      chlenfl = "Chg Len"
		  chlabfl = "Chg Lab"
		  chfmtfl = "Chg Fmt"
		  chinffl = "Chg Inf";
	if ^missing(oldtype)   and ^missing(newtype)   and oldtype   ne newtype   then chtypfl='Y';
	if ^missing(oldlength) and ^missing(newlength) and oldlength ne newlength then chlenfl='Y';
	if ^missing(oldlabel)  and ^missing(newlabel)  and oldlabel  ne newlabel  then chlabfl='Y';
	if ^missing(oldformat) and ^missing(newformat) and oldformat ne newformat then chfmtfl='Y';
	if ^missing(oldinfmt)  and ^missing(newinfmt)  and oldinfmt  ne newinfmt  then chinffl='Y';
  run;  
  
  title "All Vars that differ in type between Old and New";   proc print data=allcont; where chtypfl='Y'; var stdynamS dsname varname oldtype   newtype; run;
  title "All Vars that differ in length between Old and New"; proc print data=allcont; where chlenfl='Y'; var stdynamS dsname varname oldlength newlength; run;
  title "All Vars that differ in label between Old and New";  proc print data=allcont; where chlabfl='Y'; var stdynamS dsname varname oldlabel  newlabel; run;
  title "All Vars that differ in format between Old and New"; proc print data=allcont; where chfmtfl='Y'; var stdynamS dsname varname oldformat newformat; run;
  title "All Vars that differ in infmt between Old and New";  proc print data=allcont; where chinffl='Y'; var stdynamS dsname varname oldinfmt  newinfmt; run;
  title;
  
  *========= Output "All Studies" datasets ; 
  proc sort data=alldcat; by stdynamS dsname &BYVARS4F varname cvalstat catval; run;
  
  %global CATVALLEN;
  %global CDLSTLEN;
  %global BVARLEN;
  %global SNAMLEN;
  %global FNAMLEN;
  %global LBCATLEN;
  %global VNAMLEN;
  %global DSNAMLEN; 
  %minstrlen(alldcat, catval,    CATVALLEN);
  %minstrlen(alldcat, codelists, CDLSTLEN);
  %minstrlen(alldcat, byvars,    BVARLEN);
  %minstrlen(alldcat, stdynamS,  SNAMLEN);
  %minstrlen(alldcat, stdynamF,  FNAMLEN);
  %minstrlen(alldcat, lbcat,     LBCATLEN);
  %minstrlen(alldcat, varname,   VNAMLEN);
  %minstrlen(alldcat, dsname,    DSNAMLEN);
		
  data _outlib.ddiffcat&OUTSUFFIX (label='Derived Diff Categoricals');
    retain stdynamS actvstdyfl dsname byvars &BYVARS4F varname critvarfl inCTfl pctcat deltacat oldcount newcount cvalstat catval;
    set alldcat;
	if difffl=1;
  run;		
  
  data _outlib.ddiffmcat&OUTSUFFIX (label='Derived Missing Categoricals');
    set alldcat;
	by stdynamS dsname &BYVARS4F varname;
	retain foundone nnmisscount onmisscount;
	label nnmisscount = "New Non Missing Count"
          onmisscount = "New Non Missing Count"
		  foundone="Found a Missing";
	if first.varname then do; onmisscount=0; nnmisscount=0; foundone=0; end;
	if missing(catval) then do; foundone=1; 
	                            output;
								end;
					   else do; if ^missing(oldcount) then onmisscount=onmisscount+oldcount;
					            if ^missing(newcount) then nnmisscount=nnmisscount+newcount;
								end;
	if last.varname and foundone=1
	   then do; oldcount=onmisscount;
	            newcount=nnmisscount;
				catval="^MISSING";
				delta=.;
				percentage=.;
				pctcat='';
				deltacat='';
				output;
				end;
  run;
  		
  data _outlib.ddiffnum&OUTSUFFIX (label='Derived Diff Numeric Metrics');
    set allnum;
  run;
  
  data _outlib.ddiffmnum&OUTSUFFIX (label='Derived Missing Numeric Values');
    set allnum;
	
    if (innew and missing(newmean)) or (inold and missing(oldmean));
  run;
  
  data _outlib.ddiffurgc&OUTSUFFIX (label='Derived Diff Urgent Categoricals');
    set alldcat;
    if critvarfl=1 and pctcat ^in('=100%' '') and actvstdyfl=1;
  run;
  
  data _outlib.ddiffurgn&OUTSUFFIX (label='Derived Diff Urgent Numericals');
    set allnum;
    if critvarfl=1 and deltamean ^in(0 .) and pctstddevcat ^in("=100%" '') and actvstdyfl=1;
  run;
  
  data _outlib.ddiffcont&OUTSUFFIX (label='Derived Diff Categoricals');
    retain stdynamS actvstdyfl dsname varname varcat inold innew oldmodate newmodate chtypfl chlenfl  chlabfl  chfmtfl chinffl 
				                             oldtype newtype oldtypec newtypec oldlength newlength oldlabel newlabel oldformat newformat oldinfmt newinfmt;
    set allcont;
  run;
  
  data _outlib.ddiffdsets&OUTSUFFIX (label='All Dsets');
    set alldsets;
  run;
  
  data _outlib.ddiffstdys&OUTSUFFIX (label='All Dsets');
    set allstudies;
  run;
  
  data coverdset;
    set coverdset end=eof;
	output;
	if eof then do; ord=3;  name="Study Count (including POOLED study):"; value="&LASTSTUDY"; output; 
		            ord=5;  name="Time of Data Scan End:";                value=put(datetime(),datetime.); output;
					ord=89; name="  Categorical By Variables";                    value="&UNIQBVLSTF"; output;
					ord=90; name="  Categorical By Variable Lengths";             value="&UNIQBVLENF"; output;
					ord=91; name="  Categorical By Variable Missing Statement";   value="&UNIQBVMISF"; output;
					ord=89; name="  Numeric By Variables";                        value="&UNIQBVLSTM"; output;
					ord=90; name="  Numeric By Variable Lengths";                 value="&UNIQBVLENM"; output;
					ord=91; name="  Numeric By Variable Missing Statement";       value="&UNIQBVMISM"; output;
                    end;
  run;
  
  proc sort data=coverdset; by ord name; run;
  
  data _outlib.ddiffcvr&OUTSUFFIX(label='Cover Dsets');
    set coverdset;
  run;

  
  %if &DEBUG=Y
      %then %do; title allcont:; 
                 title2 "Old: &OLDRDIR\data\derived\*";
                 title3 "New: &NEWRDIR\data\derived\*";
                 proc print data=allcont; run;
				 %end;

%mend mcr_isafe_value_checker;


  
*======== MACRO TO COMPARE 1 STUDY, OLD AND NEW VERSIONS;
%macro diff1study();
  
  *===== Get the list of datasets in new and old;
  %if "&&FRUN&I" eq "POOLED" %then %do; %list_files(&NEWRDIR\data\derived\, newfiles);
                                        %list_files(&OLDRDIR\data\derived, oldfiles);
				        data newfiles;  set newfiles;  length pooledfl $1; pooledfl='Y'; run;
				        data oldfiles; set oldfiles; length pooledfl $1; pooledfl='Y'; run;
                                        %end;
			     %else %do; %list_files(&NEWRDIR\data\derived\&&FRUN&i, newfiles);
                                        %list_files(&OLDRDIR\data\derived\&&FRUN&i, oldfiles);
				        data newfiles;  set newfiles;  length pooledfl $1; pooledfl='N'; run;
				        data oldfiles; set oldfiles; length pooledfl $1; pooledfl='N'; run;
				        %end;
  data newdsets;
    set newfiles;
	length dsname $50;
	sufxindx = index(fname, ".sas7bdat");
	if sufxindx>0;
	if index(fname, "copy.")>0;
	dsname=substr(fname, 1, sufxindx-1);
	dsname=lowcase(dsname);
  run;
  
  data olddsets;
    set oldfiles;
	length dsname $50;
	sufxindx = index(fname, ".sas7bdat");
	if sufxindx>0;
	if index(fname, "copy.")>0;
	dsname=substr(fname, 1, sufxindx-1);
	dsname=lowcase(dsname);
  run;
  
  %if &DEBUG=Y
      %then %do; title "newfiles. newdir: &&NEWRDIR\data\derived\&&FRUN&i ";
                 proc print data=newfiles; run;
		 title "oldfiles. OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 proc print data=oldfiles; run;
		 title;
		 %end;
  
  proc sort data=newdsets; by dsname; run;
  proc sort data=olddsets; by dsname; run;  
  data  studydsets; 
    merge newdsets(in=_innew) 
          olddsets(in=_inold); 
    by dsname; 
	label dsname     = "Dataset Name~"
	      stdynamF   = "FS Study Name~"
	      stdynamS   = "SAS Study Name~"
	      innew      = "In New~"
	      inold      = "In Old~";
	length stdynamF stdynamS $50;
	stdynamF="&&FRUN&i"; 
	stdynamS="&&SRUN&i"; 
	inold=_inold;
	innew=_innew;
  run;
  
    %if &DEBUG=Y
      %then %do; title "studydsets. stdynamF: &&FRUN&i ";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
	             title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
                 proc print data=studydsets; var stdynamF stdynamS dsname innew inold;
				 run;
				 title;
				 %end;
	
  %if "&&FRUN&i" eq "POOLED" %then %do; libname newlib "&&NEWRDIR\data\derived\" access=READONLY;
                                       libname oldlib "&&OLDRDIR\data\derived" access=READONLY;
                                       %end;
                            %else %do; libname newlib "&&NEWRDIR\data\derived\&&FRUN&i" access=READONLY; 
                                       libname oldlib "&&OLDRDIR\data\derived\&&FRUN&i" access=READONLY;
                                       %end;
  
  *======== Run Proc Contents on each dataset to learn the variables each contains;
  data oldcont; 
    length memname name format informat $32 label $256 type length modate nobs 8; 
    call missing(memname, name, format, informat, label, type, length, modate, nobs); 
  stop; run;  
  
  data newcont; 
    length memname name informat format $32 label $256 type length modate nobs 8; 
    call missing(memname, name, format, informat, label, type, length, modate, nobs); 
  stop; run; 
    
  data dexecstrs (label="Dataset Execute Strings");
    set studydsets;
	length execstr $5000;
	
	execstr = catx(" ", cats("%", "nrstr("));
    if innew then execstr = catx(" ", execstr,		                   				
		                    cats("proc contents data=newlib.", dsname), "noprint out=_newcont; run;",
						    "data newcont; set newcont _newcont; run;");
	if inold then execstr = catx(" ", execstr,	                   
		                    cats("proc contents data=oldlib.", dsname), "noprint out=_oldcont; run;",				
						    "data oldcont; set oldcont _oldcont; run;");
	execstr = catx(" ", execstr, ");");
  run;
/*
	if innew and inold;
	execstr = catx(" ", cats("%", "nrstr("),	                   
		                cats("proc contents data=oldlib.", dsname), "noprint out=_oldcont; run;",				
		                cats("proc contents data=newlib.", dsname), "noprint out=_newcont; run;",
						
						*JPG got "lock not available" error here.  Need to not overwrite here too, I guess;
						"data oldcont; set oldcont _oldcont; run;",
						"data newcont; set newcont _newcont; run;)");
*/


  %if &DEBUG=Y
      %then %do; title dexecstrs;
	  	         title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
	             title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
                 proc report data=dexecstrs; 
                   column execstr;
                   define execstr /display flow width=100;
                 run;
                 title;
				 %end;
 
    data _null_;
      set dexecstrs;
	  call execute(execstr);
    run;
  
  %if &DEBUG=Y
      %then %do; %let OCLAUSE=(obs=10);
				 %let OCLAUSE=;
				 title "oldcont &OCLAUSE"; 
				 title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
	             title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
				 proc print data=oldcont &OCLAUSE; *var memname name type length format label; run;
                 title "newcont &OCLAUSE"; 
				 title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
	             title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
				 proc print data=newcont &OCLAUSE; var memname name type length format label; run;
                 title;
				 %end;

 
  proc sort data=oldcont; by memname name; run;
  proc sort data=newcont; by memname name; run;
  
  
  %macro minstrlen(_nameds, _namevar, _namemacvar);
    %global &_namemacvar;
	%let &_namemacvar =8;
	proc sql noprint; select count(*) into :msdsobscnt from &_nameds; quit; run;
	data _null_;
      dsid=open("&_nameds");
      check=varnum(dsid,"&_namevar");
      if check=0 then call symput("MINSTREXIST", "NO");
	             else call symput("MINSTREXIST", "YES");
    run;
	%if &msdsobscnt>0 and &MINSTREXIST="YES"
	    %then %do; data _null_;
                     set &_nameds end=eof;
                     retain maxvallen 0;
                     thislen=length(&_namevar);
                     if maxvallen<thislen then maxvallen=thislen;
                     if eof then call symput("&_namemacvar", strip(vvalue(maxvallen)));
                   run; 
	               data &_nameds;
                     set &_nameds(rename=(&_namevar=_&_namevar));
                     length &_namevar $&&&_namemacvar;
                     &_namevar=_&_namevar;
                     if &_namevar ne _&_namevar then putlog "WARN" "ING: truncated &_namevar in &_nameds";
                     drop _&_namevar;
                   run;
	               %end;
  %mend;

  %global MAXOLDLABELLEN;  
  %global MAXNEWLABELLEN;
  %let MAXOLDLABELLEN=1;  *in case datasets are empty;
  %let MAXNEWLABELLEN=1;
  %minstrlen(oldcont, label, MAXOLDLABELLEN);
  %minstrlen(newcont, label, MAXNEWLABELLEN);
  %PUT MAXOLDLABELLEN: &MAXOLDLABELLEN MAXNEWLABELLEN: &MAXNEWLABELLEN;
  %if &MAXNEWLABELLEN<40 %then %do; %let MAXNEWLABELLEN=40; %end;
  %if &MAXOLDLABELLEN<40 %then %do; %let MAXOLDLABELLEN=40; %end;
  %PUT MAXOLDLABELLEN: &MAXOLDLABELLEN MAXNEWLABELLEN: &MAXNEWLABELLEN;
 

  * Merge old and new content into studycont, where we can show old and new values side by side;				 
  data studycont;
    merge oldcont(in=_inold rename=(label=oldlabel format=oldformat type=oldtype length=oldlength informat=oldinfmt modate=oldmodate)) 
	      newcont(in=_innew rename=(label=newlabel format=newformat type=newtype length=newlength informat=newinfmt modate=newmodate));
	by memname name;
    label newlabel  = "New LABEL"
	      oldlabel  = "Old LABEL"
	      newformat = "New FORMAT"
	      oldformat = "Old FORMAT"
	      newtype   = "New TYPE"
	      oldtype   = "Old TYPE"
	      newlength = "New LENGTH"
	      oldlength = "Old LENGTH"
	      newinfmt  = "New INFORMAT"
	      oldinfmt  = "Old INFORMAT"
		  newmodate = "New Modified Date"
		  oldmodate = "Old Modified Date";
	length stdynamF stdynamS $50;
	stdynamF="&&FRUN&i";
	stdynamS="&&SRUN&i";
	inold=_inold;
	innew=_innew;
  run;
  
      
  data studycont;
    set studycont(rename=(memname=dsname name=varname));
	length oldtypec newtypec $4;
	if oldtype=1 then oldtypec="Num";
	if oldtype=2 then oldtypec="Char";
	if newtype=1 then newtypec="Num";
	if newtype=2 then newtypec="Char";
	varname=lowcase(varname);
	dsname=lowcase(dsname);
  run;
  

  
  proc sort data=studycont; by varname; run;
  
  data studycont;
    merge studycont(in=inalldcat) critvars(in=incrit);
    by varname;
	if inalldcat;
	if incrit then critvarfl=1;
	          else critvarfl=0;
  run;
  
  %if &DEBUG=Y %then %do; title studycont with critvars;
                         proc contents data=studycont;                          
						 proc print data=studycont; 
						    var stdynamS dsname varname critvarfl oldmodate newmodate;
						 run;
                         title;
                         %end;

  /*======== Check for byvars errors.  byvar specified in LUT must be in the dataset
   * for each dataset
   * for each variableextract byvar varnames
   * Confirm that each byvar exists in that dataset.
   * if not, warn and remove it from byvars;
   */
  proc sort data=studycont; by stdynamS dsname varname; run;

  data checkbyvars;
    set studycont;
	by stdynamS dsname varname;
	length delims $5 byvar $40;
	delims=' 	,';
	if ^missing(byvars) 
	   then do; numbvars=countw(byvars, delims);
	            do bvindx=1 to numbvars;
				  byvar=scan(byvars, bvindx, delims);
				  output;
				  end;
	            end;
	keep stdynamS dsname varname byvar;
  run;

  %if &DEBUG=Y %then %do; title checkbyvars Check for BYVAR errors between LUT and datasets; 
                          proc print data=checkbyvars; 
                            var stdynamS dsname varname byvar;
                          run;
                          title;
						  %end;
  
  
  proc sort data=studycont; by stdynamS dsname varname; run;
  proc sort data=checkbyvars; by stdynamS dsname byvar; run;
  
  data missingbyvars;  
    merge checkbyvars (in=_inbv) studycont(in=_insc rename=(varname=byvar));
	by stdynamS dsname byvar;
	inbv=_inbv;
	insc=_insc;
	if inbv and ^insc;
	if ^missing(byvar)
	   then do; *putlog "WARN" "ING: BYVAR from Crit Vars LUT, " byvar " not found for " varname " in &&FRUN&i " dsname;
	            output;
				end;
    keep stdynamS dsname varname byvar inbv insc;
  run;
  
  %if &DEBUG=Y %then %do; title missingbyvars.  BYVARS specified in CritVars LUT but not in datasets; 
                          proc print data=missingbyvars; 
                            var stdynamS dsname varname byvar inbv insc;
                          run;
                          title;
						  %end;

  data missingbyvars;  
    set missingbyvars;  
    drop inbv insc;
  run;
							
  *Sometimes the dataset doesnt have the byvars specified.  Remove missing byvars and WARN
  *Dont change the order of the remaining byvars;
  data studycont;
    merge studycont(rename=(byvars=origbyvars)) missingbyvars(rename=(byvar=mbyvar));
    by stdynamS dsname varname;
	label origbyvars="Original BYVARS value";
    length before after byvars $100;
	retain byvars;
	mbyvar=strip(mbyvar);
	if first.varname then do; byvars=origbyvars; end;
	if ^missing(mbyvar)
	   then do; putlog "seeking bad byvar: " mbyvar " in " byvars;
	            badindx = index(byvars, strip(mbyvar));
	            badlen=length(mbyvar);
				byvarslen=length(byvars);
                putlog "badindx: " badindx " badlen: " badlen " byvarslen: " byvarslen;
			    if badindx>1 then before = substr(byvars, 1, badindx-1);
					         else before='';
				if badindx+badlen+1 < byvarslen then after = substr(byvars, badindx+badlen+1);
					                            else after ='';
				byvars = catx(' ', before, after);
				putlog "removed bad byvar: " mbyvar " from " byvars;
				putlog "badindx: " badindx " badlen: " badlen " before: " before " after: " after;
				end;
	if last.varname 
	   then do; output;
	            if byvars ne origbyvars 
				   then putlog "NOTE: Removed byvars missing from &&FRUN&i " dsname  " for " varname ".  Changed from '" origbyvars "' to '" byvars "'";
			    end;
  run;
  
  Title Problem Byvars DEBUG;
  title2 If the Crit Vars LUT specifies a byvar that is not in the dataset, we drop that byvar for that dataset;
  title3 studycont byvar fix; 
  proc print data=studycont;
    var stdynamS dsname varname badindx badlen byvarslen before after byvars origbyvars;                          
    where byvars ne origbyvars;
  run;
  title;

  data studycont;
    set studycont;
    drop badindx badlen byvarslen before after mbyvar;
  run;
  
  *==============================================;
  

  

  *====== categorize the variables into categoricals, IDs, dates, visits, ranges, etc.;
  data studycont;
  set studycont end=eof;
    length varcat $20;
	retain maxcatlen 0;
    if index(upcase(oldformat), "DATE")>0 or index(upcase(newformat), "DATE")>0 then varcat="DATE";
	vnamelen=length(varname);
	if index(upcase(varname), "DT")=vnamelen-1 then varcat="DATE";
	if index(upcase(varname), "DTC")=vnamelen-2 then varcat="DATE";
	if index(upcase(varname), "SEQ")=vnamelen-2 then varcat="SEQUENCE";
	if index(upcase(varname), "_DD")=vnamelen-2 then varcat="DAYOFMONTH";
	if index(upcase(varname), "_MM")=vnamelen-2 then varcat="MONTHOFYEAR";
	if index(upcase(varname), "_YYYY")=vnamelen-4 then varcat="YEAR";
	if index(upcase(varname), "ID")=vnamelen-1 then varcat="ID"; 
	if index(varname, "ID")>0 then putlog "varname: " varname " vnamelen: " vnamelen " varcat: " varcat;
	if index(varname, "DTC")>0 then putlog "varname: " varname " vnamelen: " vnamelen " varcat: " varcat;
	if index(upcase(varname), "DT")=vnamelen-2 then varcat="DATE";
    if missing(varcat) and (index(upcase(oldformat), "TIME")>0 or index(upcase(oldformat), "TIME")>0 ) then varcat="TIME";
    if missing(varcat) and newtypec="Num" and index(upcase(varname), "CD") ne vnamelen-1 then varcat="NUMERIC";
    if missing(varcat) and newtypec="Char" then do; varcat="CATEGORICAL";
	                                              if newlength>maxcatlen then maxcatlen=newlength;
	                                              if oldlength>maxcatlen then maxcatlen=oldlength;
												  end;
	*if missing(varcat) and index(upcase(varname), "CD")=vnamelen-1 then varcat="CODE";
	if eof then call symput ("MAXCATLEN", strip(vvalue(maxcatlen)));											  
  run;
  

 %if &DEBUG=Y %then %do;  
                        title "studycont with categories";
                        title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                        title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
                        proc print data=studycont;
                          var stdynamS stdynamF dsname varname newtype newtypec newlength varcat newlabel newmodate oldmodate;
                        run;
                        title;
                        %end;
  *======================================================;
	
  *========= Get last modified date from source and freqout datasets, so we can determine if we need to rebuild freqout;
  %let OLMODATE=0;
  data _null_;
    set oldcont end=eof;
	retain lmodate 0;
	if lmodate<modate then lmodate=modate;
	if eof then call symput("OLMODATE", strip(vvalue(lmodate))); 
  run;  
  
  %let NLMODATE=0;
  data _null_;
    set newcont end=eof;
	retain lmodate 0;
	if lmodate<modate then lmodate=modate;
	if eof then call symput("NLMODATE", strip(vvalue(lmodate))); 
  run;
  
  data _null_;
    length newpath oldpath $500;
    newpath="&&NEWRDIR";
    newlen = length(newpath);
	if substr(newpath, newlen) = '\' then newpath = substr(newpath, 1, newlen-1);
	newrun=scan(newpath, -1, '\');
	call symput ("NEWRUNNAM", strip(newrun));
    oldpath="&&OLDRDIR";
    oldlen = length(oldpath);
	if substr(oldpath, oldlen) = '\' then oldpath = substr(oldpath, 1, oldlen-1);
	oldrun=scan(oldpath, -1, '\');
	call symput ("OLDRUNNAM", strip(oldrun));
  run;

  options DLCREATEDIR;						  
  libname justck1 "&IDSPATH\&OLDRUNNAM";
  libname justck2 "&IDSPATH\&NEWRUNNAM";
  libname oldfqlib "&IDSPATH\&OLDRUNNAM\&&FRUN&I";
  libname newfqlib "&IDSPATH\&NEWRUNNAM\&&FRUN&I";
  options NODLCREATEDIR;	

  /* If we build the MO or FO datasets, we calculate the BYVARS4F and BYVARS4M.
   * If we read them in as intermediate datasets, we extract BYVARS4F and BYVARS4M
   * from the sortedby info in those datasets.
   */
	%macro getbvfromDS(_dataset, _contout, _macvarnam);
	  %global &_macvarnam;
	  %let &_macvarnam=;
      data srtvars;
	    set &_contout;
	    if ^missing(sortedby);
	    if lowcase(name) ^in('dsname' 'varname');
	    keep name sortedby;
	  run;
	  proc sort data=srtvars; by sortedby; run;
	  data _null_;
	    set srtvars end=eof;
	    length _bvstr $500;
	    retain _bvstr '';
	    _bvstr=catx(' ', _bvstr, name);
	    if eof then do; call symput("&_macvarnam", strip(_bvstr));
	                    putlog "setting &_macvarnam from &_dataset to: " _bvstr;
		  			    end;
	  run;
	%mend;  

  * Check to see if the Old Freq Out (OFO) dataset exists for this run.  If so, run proc contents on the dataset to
  * get its Last Modified date.;
  %if %sysfunc(exist(oldfqlib.fo&&SRUN&I)) 
      %then %do; proc contents data=oldfqlib.fo&&SRUN&I out=ofocont noprint; run;
	             %getbvfromDS(      oldfqlib.fo&&SRUN&I,    ofocont, BYVARS4F);
				 data _null;
                   set ofocont end=eof;
	               retain lmodate 0;
	               if lmodate<modate then lmodate=modate;
	               if eof then call symput("OFOLMODATE", strip(vvalue(lmodate))); 
                 run;
	             %end;
	  %else %do; %let OFOLMODATE = 0; %end;

  * Check to see if the New Freq Out (NFO) dataset exists for this run.  If so, run proc contents on the dataset to
  * get its Last Modified date.;	  
  %if %sysfunc(exist(newfqlib.fo&&SRUN&I)) 
      %then %do; proc contents data=newfqlib.fo&&SRUN&I out=nfocont noprint; run; 
	             %getbvfromDS(      newfqlib.fo&&SRUN&I,    nfocont, BYVARS4F);
				 data _null;
                   set nfocont end=eof;
	               retain lmodate 0;
	               if lmodate<modate then lmodate=modate;
	               if eof then call symput("NFOLMODATE", strip(vvalue(lmodate))); 
                 run;
	             %end;
	  %else %do; %let NFOLMODATE = 0; %end;
	  
  * Check to see if the Old Means Out (OMO) dataset exists for this run.  If so, run proc contents on the dataset to
  * get its Last Modified date.;
  %if %sysfunc(exist(oldfqlib.mo&&SRUN&I)) 
      %then %do; proc contents data=oldfqlib.mo&&SRUN&I out=omocont noprint; run;
	             %getbvfromDS(      oldfqlib.mo&&SRUN&I,    omocont, BYVARS4M);
				 data _null;
                   set omocont end=eof;
	               retain lmodate 0;
	               if lmodate<modate then lmodate=modate;
	               if eof then call symput("OMOLMODATE", strip(vvalue(lmodate))); 
                 run;
	             %end;
	  %else %do; %let OMOLMODATE = 0; %end;

  * Check to see if the New Means Out (NMO) dataset exists for this run.  If so, run proc contents on the dataset to
  * get its Last Modified date.;	  
  %if %sysfunc(exist(newfqlib.mo&&SRUN&I)) 
      %then %do; proc contents data=newfqlib.mo&&SRUN&I out=nmocont noprint; run; 
	             %getbvfromDS(      newfqlib.mo&&SRUN&I,    nmocont, BYVARS4M);			   
	             data _null;
                   set nmocont end=eof;
	               retain lmodate 0;
	               if lmodate<modate then lmodate=modate;
	               if eof then call symput("NMOLMODATE", strip(vvalue(lmodate))); 
                 run;
	             %end;
	  %else %do; %let NMOLMODATE = 0; %end;
  *=========================;

				
  data _null_;
    length nfostr nlmstr ofostr olmstr $25 bigstr $200;
    if &NFOLMODATE = 0 then nfostr="0"; else nfostr="%sysfunc(putn(&NFOLMODATE, datetime.))";
    if &NLMODATE   = 0 then nlmstr="0"; else nlmstr="%sysfunc(putn(&NLMODATE,   datetime.))";
    if &OFOLMODATE = 0 then ofostr="0"; else ofostr="%sysfunc(putn(&OFOLMODATE, datetime.))";
    if &OLMODATE   = 0 then olmstr="0"; else olmstr="%sysfunc(putn(&OLMODATE,   datetime.))";
    bigstr = catx(' ', "NFOLMODATE:",     nfostr,
                       "vs NLMODATE:",    nlmstr,
                       "and OFOLMODATE:", ofostr,
                       "vs OLMODATE:",    olmstr);
    putlog bigstr;
  run;


  *if freqout dataset on disk is older than its inputs, then re-build it.  Otherwise, read it in from disk;
  *JPG -- refactor this so you do new or old as needed, not both if either are needed.;
  %if &NFOLMODATE=0 or &OFOLMODATE=0 or &NFOLMODATE<&NLMODATE or &OFOLMODATE<&OLMODATE or &ALWAYSBUILD=Y
      %then %do; %buildfreqout(); %end;
      %else %do; %readfreqout();  %end;
	
  %if &NFOLMODATE=0 or &OFOLMODATE=0 or &NMOLMODATE<&NLMODATE or &OMOLMODATE<&OLMODATE or &ALWAYSBUILD=Y
      %then %do; %buildmeansout(); %end;
      %else %do; %readmeansout();  %end;
  
  *=====================================================;
  	%macro mkfltrvals(_var);
	  length delta&_var.cat $10 pct&_var.cat $12;
	  if ^missing(new&_var) and ^missing(old&_var) then delta&_var = new&_var-old&_var;
	  if ^missing(new&_var) and ^missing(old&_var) and old&_var ne 0 then pct&_var = new&_var/old&_var*100;
	  if      delta&_var.<= -100 then delta&_var.cat=     "x<-100";
	  if -100<delta&_var.<=  -50 then delta&_var.cat="-100<x<-50";
	  if  -50<delta&_var.<=  -10 then delta&_var.cat= "-50<x<-10";
	  if  -10<delta&_var.<=   -1 then delta&_var.cat= "-10<x<-1";
	  if   -1<delta&_var.<=    0 then delta&_var.cat=  "-1<x<0";
	  if      delta&_var. =    0 then delta&_var.cat=     "x=0";
	  if    0<delta&_var.<=    1 then delta&_var.cat=   "0<x<=1";
	  if    1<delta&_var.<=   10 then delta&_var.cat=   "1<x<=10";
	  if   10<delta&_var.<=   50 then delta&_var.cat=  "10<x<=50";
	  if   50<delta&_var.<=  100 then delta&_var.cat=  "50<x<=100";
	  if  100<delta&_var.        then delta&_var.cat= "100<x";				
	
	  if     pct&_var.<   0 then pct&_var.cat=    "x<0%";	  
	  if     pct&_var.=   0 then pct&_var.cat=    "x=0%";
	  if   0<pct&_var.<= 10 then pct&_var.cat= "0%<x<=10%";
	  if  10<pct&_var.<= 20 then pct&_var.cat="10%<x<=20%";
	  if  20<pct&_var.<= 30 then pct&_var.cat="20%<x<=30%";
	  if  30<pct&_var.<= 40 then pct&_var.cat="30%<x<=40%";
	  if  40<pct&_var.<= 50 then pct&_var.cat="40%<x<=50%";
	  if  50<pct&_var.<= 60 then pct&_var.cat="50%<x<=60%";
	  if  60<pct&_var.<= 70 then pct&_var.cat="60%<x<=70%";
	  if  70<pct&_var.<= 80 then pct&_var.cat="70%<x<=80%";
	  if  80<pct&_var.<= 90 then pct&_var.cat="80%<x<=90%";
	  if  90<pct&_var.< 100 then pct&_var.cat="90%<x<100%";
	  if     pct&_var.= 100 then pct&_var.cat="x=100%";
	  if 100<pct&_var.<=110 then pct&_var.cat="100%<x<=110%";
	  if 110<pct&_var.<=120 then pct&_var.cat="110%<x<=120%";
	  if 120<pct&_var.<=130 then pct&_var.cat="120%<x<=130%";
	  if 130<pct&_var.<=140 then pct&_var.cat="130%<x<=140%";
	  if 140<pct&_var.<=150 then pct&_var.cat="140%<x<=150%";
	  if 150<pct&_var.<=160 then pct&_var.cat="150%<x<=160%";
	  if 160<pct&_var.<=170 then pct&_var.cat="160%<x<=170%";
	  if 170<pct&_var.<=180 then pct&_var.cat="170%<x<=180%";
	  if 180<pct&_var.<=190 then pct&_var.cat="180%<x<=190%";
	  if 190<pct&_var.<=200 then pct&_var.cat="190%<x<=200%";
	  if 200<pct&_var.      then pct&_var.cat="200%<x";
    %mend mkfltrvals;	
	
	
  /*==================== RENAME OLD & NEW VARS
   * SAS wont let you rename variables if you have no observations.
   */
  proc sql noprint; select count(*) into :OLDMOBSCNT from oldmeansout; quit; run;
  proc sql noprint; select count(*) into :NEWMOBSCNT from newmeansout; quit; run;
  
  %if &NEWMOBSCNT>0 and &OLDMOBSCNT>0 
      %then %do; data studymeansout;
                   merge newmeansout(rename=(n=newn mean=newmean median=newmedian max=newmax min=newmin range=newrange nmiss=newnmiss stddev=newstddev) in=_innew)
	                     oldmeansout(rename=(n=oldn mean=oldmean median=oldmedian max=oldmax min=oldmin range=oldrange nmiss=oldnmiss stddev=oldstddev) in=_inold);
	               by dsname varname &BYVARS4M;
	               innew=_innew;
	               inold=_inold;
	             run;
                 %end;
  %if &NEWMOBSCNT>0 and &OLDMOBSCNT=0 
       %then %do; data studymeansout;
                   set newmeansout(rename=(n=newn mean=newmean median=newmedian max=newmax min=newmin range=newrange nmiss=newnmiss stddev=newstddev) in=_innew);
				   call missing(oldn, oldmean, oldmedian, oldmax, oldmin, oldrange, oldnmiss, oldstddev);
	               by dsname varname &BYVARS4M;
	               innew=_innew;
	               inold=0;
	             run;
                 %end;  
  %if &NEWMOBSCNT=0 and &OLDMOBSCNT>0 
      %then %do; data studymeansout;
                   set oldmeansout(rename=(n=oldn mean=oldmean median=oldmedian max=oldmax min=oldmin range=oldrange nmiss=oldnmiss stddev=oldstddev) in=_inold);
				   call missing(newn, newmean, newmedian, newmax, newmin, newrange, newnmiss, newstddev);
	               by dsname varname &BYVARS4M;
	               innew=0;
	               inold=_inold;
	             run;
                 %end;  
  %if &NEWMOBSCNT=0 and &OLDMOBSCNT=0 
      %then %do; data studymeansout;
                   call missing(oldn, oldmean, oldmedian, oldmax, oldmin, oldrange, oldnmiss, oldstddev);
                   call missing(newn, newmean, newmedian, newmax, newmin, newrange, newnmiss, newstddev);
	               innew=0;
	               inold=0;
	             run;
                 %end;
  /*==================== FINISHED RENAMING OLD & NEW VARS
   */ 


  data studymeansout;
    set studymeansout;
	length mvalstat $4 stdynamF stdynamS $50;
	label newnmiss=' ' oldnmiss=' ';

	%mkfltrvals(n);
	%mkfltrvals(mean);   
	%mkfltrvals(median); 
	%mkfltrvals(max);    
	%mkfltrvals(min);    
	%mkfltrvals(range); 	
	%mkfltrvals(nmiss);  
	%mkfltrvals(stddev); 
	
    stdynamF="&&FRUN&i";
	stdynamS="&&SRUN&i";
	if  innew and  inold then mvalstat="BOTH";
	if ^innew and  inold then mvalstat="OLD";
	if  innew and ^inold then mvalstat="NEW";
	if ^innew and ^inold then mvalstat="NONE";
  run;
  
  proc sort data=newfreqout; by dsname varname &BYVARS4F catval; run;
  proc sort data=oldfreqout; by dsname varname &BYVARS4F catval; run;
  *=====================================================;
  data studyfreqout;
    merge newfreqout(in=_innew rename=(count=newcount)) oldfreqout(in=_inold rename=(count=oldcount));
    by dsname varname &BYVARS4F catval;
	label oldcount= "Old Count"
	      newcount= "New Count"
		  catval="Categorical Value"
		  cvalstat="In Which";
	length cvalstat $4 stdynamF stdynamS $50;
	stdynamF="&&FRUN&i";
	stdynamS="&&SRUN&i";
	inold=_inold;
	innew=_innew;
	if  innew and  inold then cvalstat="BOTH";
	if ^innew and  inold then cvalstat="OLD";
	if  innew and ^inold then cvalstat="NEW";
	if ^innew and ^inold then cvalstat="NONE";
  run;
  

  data studydiff;
    set studyfreqout;
    by dsname varname &BYVARS4F catval;
	retain difffl;
	if first.varname then difffl=0;
	if cvalstat in ("OLD" "NEW") then difffl=1;
	if last.varname and difffl=1 then output;
	keep dsname varname difffl;
  run;
  
%if &DEBUG=Y
      %then %do; %let OCLAUSE=;
	             title "studydiff&OCLAUSE study variables where categorical freqs do not match";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc print data=studydiff&OCLAUSE label; run;
				 title;
				 %end;
  
  data studyfreqout;
    merge studyfreqout studydiff;
	by dsname varname;
  run;

  %if &DEBUG=Y
      %then %do; title "studyfreqout: Study Freq output with differing variables flagged";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc report data=studyfreqout split='~'; 
                   column stdynamS stdynamF dsname varname difffl oldcount newcount cvalstat catval;
				   define stdynamS /display flow width=10;
				   define stdynamF /display flow width=10;
				   define dsname   /display flow width=25;
				   define varname  /display flow width=32;
				   define difffl   /display width=4;
				   define oldcount   /display width=5;
				   define newcount   /display width=5;
				   define cvalstat /display width=5;
				   define catval   /display flow width=90;
                 run;
				 title;
				 %end;
  
  data studydcat;
    set studyfreqout;
	numericval=input(catval, ?? best.);
	if ^missing (numericval) then delete;
	keep stdynamS stdynamF difffl dsname byvars varname critvarfl oldcount newcount cvalstat catval &BYVARS4F;
  run;
  
  %if &DEBUG=Y
      %then %do; title "studydcat: Study differing categorical variables with numeric values removed";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc report data=studydcat split='~'; 
                   column stdynamS stdynamF dsname varname difffl oldcount newcount cvalstat catval;
				   define stdynamS /display flow width=10;
				   define stdynamF /display flow width=10;
				   define dsname   /display flow width=25;
				   define varname  /display flow width=10;
				   define difffl   /display width=4;
				   define oldcount   /display width=5;
				   define newcount   /display width=5;
				   define cvalstat /display width=5;
				   define catval   /display flow width=90;
                 run;
				 title;
				 %end;

%mend diff1study;


*======================================================================;


  
%macro readmeansout(); 
  data oldmeansout; set oldfqlib.mo&&SRUN&I; run;
  data newmeansout; set newfqlib.mo&&SRUN&I; run; 

  ods listing close;
  ods output ExtendedattributesDS=oldxattr;
  proc contents data=oldfqlib.mo&&SRUN&I; run;
  ods output ExtendedattributesDS=newxattr;
  proc contents data=newfqlib.mo&&SRUN&I; run;
  ods listing;
  data byvardsM;
    set oldxattr newxattr; 
	length delims $5 byvar $40;
	delims=' 	,';
	if ExtendedAttribute="ddiffbyvars" 
	   then byvars=AttributeCharValue;
	if ^missing(byvars)
	   then do; numbvars=countw(byvars, delims);
	            do bvindx=1 to numbvars;
				  byvar=scan(byvars, bvindx, delims);				  
				  output;
				  end;
				end;
    keep byvar;
  run;	
  proc sort data=byvardsM nodupkey; by byvar; run;
%mend;

* freqout datasets take a long time to create, so we save them to disk
* and read them in if the data they are derived from has not changed.
* We need the BYVARS also, which are stored as extended attributes on
* the datasets.;
%macro readfreqout();  
  data oldfreqout;  set oldfqlib.fo&&SRUN&I; run;
  data newfreqout;  set newfqlib.fo&&SRUN&I; run;
  
  ods listing close;
  ods output ExtendedattributesDS=oldxattr;
  proc contents data=oldfqlib.fo&&SRUN&I; run;
  ods output ExtendedattributesDS=newxattr;
  proc contents data=newfqlib.fo&&SRUN&I; run;
  ods listing;
  data byvardsF;
    set oldxattr newxattr; 
	length delims $5 byvar $40;
	delims=' 	,';
	if ExtendedAttribute="ddiffbyvars" 
	   then byvars=AttributeCharValue;
	if ^missing(byvars)
	   then do; numbvars=countw(byvars, delims);
	            do bvindx=1 to numbvars;
				  byvar=scan(byvars, bvindx, delims);				  
				  output;
				  end;
				end;
    keep byvar;
  run;	
  proc sort data=byvardsF nodupkey; by byvar; run;
%mend;





%macro buildfreqout();  
				 
/*JPG 3MAR2022
 * We have an internal SAS bug we're triggering by overwriting _oldfrqout and _newfrqout and appending them to oldfreqout and newfreqout  
 * so many times in a tight loop.  When the bug happens, which seems more likely the faster the server, we get one or more of the following:
 * ERROR: A lock is not available for WORK._newfrqout.DATA.
 * ERROR: A lock is not available for WORK._oldfrqout.DATA.
 * ERROR: A lock is not available for WORK.oldfreqout.DATA.
 * ERROR: A lock is not available for WORK.newfreqout.DATA.
 * In consecutive identical runs, the bug does not happen at the same place in the data.
 * I suspect the error message is not really indicative of the problem, since there is only one process involved and the datasets 
 * do not exist on disk.  The errors don't always happen, and they're less likely when the SAS server is heavily loaded and very slow,
 * so this seems like an internal threading or timing error.  I suspect the act of releasing the lock is still happening when the lock
 * is next set, so that lock set fails.
 * I turned off the threads (option nothreads), and that didn't help.  
 * I added some proc dataset commands to introduce delays and perhaps clear the locks and/or avoid the timing issue, but that also did not work.
 * Deleting the temporary dataset before re-creating it also did not work.
 * I stopped re-using the temporary _newfrqout and _oldfrqout datasets, and appended _N_ to the dataset names to make them unique each time 
 * through the loop.  Also appended _N_ to the accumulating datasets, oldfreqout and newfreqout, to make them unique each time through the loop so 
 * they are also not vulnerable to unlocking timing issues.
 *
 * dont reuse the temporary dataset.  Put an incrementing number on the end.  Maybe also increment the cumulative dataset.
 * Maybe break into multiple execute statements.
 *
 */			 
				 
  data cexecstrs;
    set studycont;
	length byclause $1000;
	if innew and inold and varcat="CATEGORICAL";
	if ^missing (byvars) then byclause=catx(' ', "by", byvars);
	                     else byclause='';
	
  run;
    
  *======== Build clause of all byvars used in this dataset;
  data byvardsF;
    set cexecstrs end=eof;
	length delims $5 byvar $40;
	delims=' 	,';
	if ^missing(byvars)
	   then do; numbvars=countw(byvars, delims);
	            do bvindx=1 to numbvars;
				  byvar=scan(byvars, bvindx, delims);				  
				  output;
				  end;
				end;
    keep byvar;
	run;
	
  proc sort data=byvardsF nodupkey; by byvar; run;
  proc sort data=studycont nodupkey; by varname; run;
  
  *get length and type info for byvars;
  data byvardsF;
    merge byvardsF (in=inbv) studycont(in=insc rename=(varname=byvar));
	by byvar;
	if inbv;
  run;
  
  proc sort data=byvardsF; by byvar; run;
  
  *Get info necessary to declare length in empty datasets;
  data byvardsF;
	set byvardsF;
	by byvar;
	retain _typ _len 0;
	if first.byvar then do; _typ=0; _len=0; end;
	if newlength>_len then _len=newlength;
	if oldlength>_len then _len=oldlength;
	if _typ=0 then _typ=newtype;	
	if _typ=0 then _typ=oldtype;
	if newtype ne _typ then putlog "WARN" "ING: SRUN&I BYVAR TYPE INCONSISTENCY. " byvar;
	if last.byvar then output;
	keep byvar _len _typ;
  run;
  
  title byvardsF F; proc print data=byvardsF; run; 
  title;

  * set to missing in case byvardsF is empty;
  %let BVCLAUSE=;
  %let BVLCLAUSE=;
  %let BVMCLAUSE=;
  %let BYVARS4F=;
  data _null_;
    set byvardsF end=eof;
	length listbyvars byvarlclause byvarsclause byvarmclause $1000;
	label byvarsclause="strvar=''; numvar=.;"
		  byvarlclause="length strvar $xx"
		  listbyvars   ="strvar numvar"
		  byvarmclause="missing(strvar, numvar);";
	retain listbyvars byvarlclause byvarmclause byvarsclause '';

	if ^missing(byvarsclause) then byvarsclause=cats(byvarsclause,", ");
	byvarsclause=cats(byvarsclause, "'", byvar, "=',", byvar, ", ';'");
	
	if _typ=2
	   then do; if missing(byvarlclause) then byvarlclause="length";
	            byvarlclause=catx(' ', byvarlclause, byvar, cats("$", vvalue(_len)));
				end;
	
	if ^missing(byvarmclause) then byvarmclause=cats(byvarmclause,",");
	                          else byvarmclause="call missing (";
	byvarmclause=cats(byvarmclause, byvar);
	
	listbyvars=catx(' ', listbyvars, byvar);
	
	if eof then do; call symput("BVCLAUSE", strip(byvarsclause));
	                byvarmclause=cats(byvarmclause, ")");
					call symput("BVLCLAUSE", strip(byvarlclause));
					call symput("BVMCLAUSE", strip(byvarmclause));
					call symput("BYVARS4F", strip(listbyvars));
					end;
  run;
  
  
  data oldfreqout1; length stdynamS stdynamF dsname $50 varname $32 catval $400 byvars $100  count 8; 
                 call missing(stdynamS, stdynamF, dsname, varname, catval, count, byvars, critvarfl);
                 &BVLCLAUSE; &BVMCLAUSE;				 
				 stop; run;  
  data newfreqout1; length stdynamS stdynamF dsname $50 varname $32 catval $400 byvars $100  count 8; 
                 call missing(stdynamS, stdynamF, dsname, varname, catval, count, byvars, critvarfl); 
				 &BVLCLAUSE; &BVMCLAUSE;
				 stop; run;  
				 
  data newfreqoutMT; set newfreqout1; run;		 
  data oldfreqoutMT; set oldfreqout1; run;	
  *======== Finished Building clause of all byvars used in this dataset;
  

  
  proc sort data=byvardsF; by byvar; run;
  %let CXNPLUS1=1;  *if we find no execute strings, this does the right thing;
  
  
  /* Code that writes code is notoriously  hard to read.  Sorry about that.
   * We have the BYCLAUSE, which is the by clause for THIS VARIABLE.
   * We also have the BVCLAUSE, which is covers all by variables for THIS DATASET.
   * We also have byvars, which came from the Crit Vars spreadsheet, and lists the by variables for THIS VARIABLE
   */
  data cexecstrs(label="Contents Execute Strings");
    set cexecstrs end=eof;
	length oldsortclause newsortclause $500 execstr $5000;
	nplus1=_N_+1;
	if ^missing(byvars) then do; oldsortclause=catx(' ', cats("proc sort data=oldlib.", dsname), "out=myoldds; by", byvars, "; run;");
	                             newsortclause=catx(' ', cats("proc sort data=newlib.", dsname), "out=mynewds; by", byvars, "; run;");
								 end;
	                      else do; oldsortclause=catx(' ', "data myoldds;", cats("set oldlib.", dsname), "; run;");
						           newsortclause=catx(' ', "data mynewds;", cats("set newlib.", dsname), "; run;");
								   end;
	
    execstr = catx(' ', cats("%", "nrstr("),
                        cats("%", "PUT STARTING:"), varname, "byvars:", cats("'", byvars, "';"),
						oldsortclause,
	                    "proc freq data=myoldds noprint; ", byclause, "; table", varname, 
							 "/list missing nocum nopercent out=", cats("_oldfrqout", vvalue(_N_)), "; run;",
						"data", cats("_oldfrqout", vvalue(_N_)), "; length catval $400; set ", cats("_oldfrqout", vvalue(_N_)), 
						                          "(rename=(", varname, "=catval)) oldfreqoutMT;", 
							                      cats("length stdynamS $50 varname $32 byvars $100 ; dsname='", dsname, 
												  "'; stdynamS='",stdynamS, "'; varname='", varname, "'; critvarfl=",
												  critvarfl, '; byvars="', byvars, '";'), 
												  "keep stdynamS dsname varname catval count byvars critvarfl", byvars, "; run;",
						"data", cats("oldfreqout", vvalue(nplus1)), "; length catval $400; set", cats("oldfreqout", vvalue(_N_)), 
							    cats("_oldfrqout", vvalue(_N_)), "; run;",
						"proc datasets library=work nolist; delete", cats("_oldfrqout", vvalue(_N_)), 
							                                         cats("oldfreqout", vvalue(_N_)), "; quit; run;",

	                    newsortclause,
						"proc freq data=mynewds noprint;", byclause, "; table", varname, 
							     "/list missing nocum nopercent out=", cats("_newfrqout", vvalue(_N_)), "; run;",
						"data", cats("_newfrqout", vvalue(_N_)), "; length catval $400; set", cats("_newfrqout", vvalue(_N_)), 
							                      "(rename=(", varname, "=catval)) newfreqoutMT;",
							                      cats("length stdynamS $50 varname $32 byvars $100 ; dsname='",dsname, 
												  "'; stdynamS='",stdynamS, "'; varname='", varname, "'; critvarfl=",
												  critvarfl, '; byvars="', byvars, '";'), 
												  "keep stdynamS dsname varname catval count byvars critvarfl", byvars, "; run;",
				        "data", cats("newfreqout", vvalue(nplus1)), "; length catval $400; set", cats("newfreqout", vvalue(_N_)), 
							    cats("_newfrqout", vvalue(_N_)), "; run;",
						"proc datasets library=work nolist; delete", cats("_newfrqout", vvalue(_N_)), 
							                                         cats("newfreqout", vvalue(_N_)), "; quit; run;",

						");");
	output;
	if eof then do; call symput("CXNPLUS1", strip(vvalue(nplus1)));
					end;
  run;



  %if &DEBUG=Y
      %then %do; title cexecstrs;
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
                 proc report data=cexecstrs split='~'; 
                   column execstr;
                   define execstr /display flow width=100;
                 run;
                 title;
				 %end;

 data _null_;
    set cexecstrs;
	call execute(execstr);
  run;
  
  data newfreqout; set newfreqout&CXNPLUS1; run;
  data oldfreqout; set oldfreqout&CXNPLUS1; run;
 
 %if &DEBUG=Y
      %then %do; %let OCLAUSE=(obs=10);
	           /*
	             title "_oldfrqout&OCLAUSE";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
				 proc print data=_oldfrqout&OCLAUSE; run;	             
				 title "_newfrqout&OCLAUSE"; 
                 title2 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc print data=_newfrqout&OCLAUSE; run;
				*/
				 title "oldfreqout&OCLAUSE";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
				 proc print data=oldfreqout&OCLAUSE; format catval $100.; var stdynamS dsname varname catval; run;
				 title "newfreqout&OCLAUSE"; 
                 title2 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc print data=newfreqout&OCLAUSE; format catval $100.; var stdynamS dsname varname catval; run;
				 title;
				 %end;

				 

  proc sort data=newfreqout; by dsname varname &BYVARS4F catval; run;
  proc sort data=oldfreqout; by dsname varname &BYVARS4F catval; run;

  
  *===========Minimize the length of the catval variable;

  %global NEWMAXCATVALLEN;
  %global OLDMAXCATVALLEN;  
  %let NEWMAXCATVALLEN=1;
  %let OLDMAXCATVALLEN=1;
  %minstrlen(newfreqout, catval, NEWMAXCATVALLEN);
  %minstrlen(oldfreqout, catval, OLDMAXCATVALLEN);

  data oldfqlib.fo&&SRUN&I(label="Study Freq Out &&SRUN&I" sortedby=dsname varname &BYVARS4F catval);
    set oldfreqout;
  run;
  %if %length(&BYVARS4F)>0 %then %do; proc datasets lib=oldfqlib nolist; modify fo&&SRUN&I; xattr add ds ddiffbyvars="&BYVARS4F"; quit; %end;
                           %else %do; proc datasets lib=oldfqlib nolist; modify fo&&SRUN&I; xattr add ds ddiffbyvars=" ";         quit; %end;
  data newfqlib.fo&&SRUN&I(label="Study Freq Out &&SRUN&I" sortedby=dsname varname &BYVARS4F catval);
    set newfreqout;
  run;
  %if %length(&BYVARS4F)>0 %then %do; proc datasets lib=newfqlib nolist; modify fo&&SRUN&I; xattr add ds ddiffbyvars="&BYVARS4F"; quit; %end;
                           %else %do; proc datasets lib=newfqlib nolist; modify fo&&SRUN&I; xattr add ds ddiffbyvars=" ";         quit; %end;
%mend buildfreqout;
*=================================================================================;



*=================================================================================;
%macro buildmeansout(); 


				 
  data cexecstrs;
    set studycont;
	length byclause $1000;
	if innew and inold and varcat="NUMERIC" and nobs>0;
	if ^missing (byvars) then byclause=catx(' ', "by", byvars);
	                     else byclause='';
	
  run;

  /*
   * for each dataset
   * for each variableextract byvar varnames
   * Confirm that each byvar exists in that dataset.
   * if not, warn and remove it from byvars;
   */
  *======== Build clause of all byvars used in this dataset;
  data byvardsM;
    set cexecstrs end=eof;
	length delims $5 byvar $40;
	delims=' 	,';
	if ^missing(byvars)
	   then do; numbvars=countw(byvars, delims);
	            do bvindx=1 to numbvars;
				  byvar=scan(byvars, bvindx, delims);				  
				  output;
				  end;
				end;
    keep byvar;
	run;
	
  proc sort data=byvardsM nodupkey; by byvar; run;
  proc sort data=studycont nodupkey; by varname; run;
  
  *get length and type info for byvars;
  data byvardsM;
    merge byvardsM (in=inbv) studycont(in=insc rename=(varname=byvar));
	by byvar;
  	if inbv;
  run;
  
  proc sort data=byvardsM; by byvar; run;

  *Get info necessary to declare length in empty datasets;
  data byvardsM;
	set byvardsM;
	by byvar;
	retain _typ _len 0;
	if first.byvar then do; _typ=0; _len=0; end;
	if newlength>_len then _len=newlength;
	if oldlength>_len then _len=oldlength;
	if _typ=0 then _typ=newtype;	
	if _typ=0 then _typ=oldtype;
	if newtype ne _typ then putlog "WARN" "ING: SRUN&I BYVAR TYPE INCONSISTENCY. " byvar;
	if last.byvar then output;
	keep byvar _len _typ;
  run;
  
  title byvardsM M; proc print data=byvardsM; run; 
  title;

  %let BVCLAUSE=;
  %let BVLCLAUSE=;
  %let BVMCLAUSE=;
  %let BYVARS4M=;
  data _null_;
    set byvardsM end=eof;
	length listbyvars byvarlclause byvarsclause byvarmclause $1000;
	label byvarsclause="strvar=''; numvar=.;"
		  byvarlclause="length strvar $xx"
		  listbyvars   ="strvar numvar"
		  byvarmclause="missing(strvar, numvar);";
	retain listbyvars byvarlclause byvarmclause byvarsclause '';

	if ^missing(byvarsclause) then byvarsclause=cats(byvarsclause,", ");
	byvarsclause=cats(byvarsclause, "'", byvar, "=',", byvar, ", ';'");
	
	if _typ=2
	   then do; if missing(byvarlclause) then byvarlclause="length";
	            byvarlclause=catx(' ', byvarlclause, byvar, cats("$", vvalue(_len)));
				end;
	
	if ^missing(byvarmclause) then byvarmclause=cats(byvarmclause,",");
	                          else byvarmclause="call missing (";
	byvarmclause=cats(byvarmclause, byvar);
	
	listbyvars=catx(' ', listbyvars, byvar);
	
	if eof then do; call symput("BVCLAUSE", strip(byvarsclause));
	                byvarmclause=cats(byvarmclause, ")");
					call symput("BVLCLAUSE", strip(byvarlclause));
					call symput("BVMCLAUSE", strip(byvarmclause));
					call symput("BYVARS4M", strip(listbyvars));
					end;
  run;
  
  
  data oldmeansout1; length stdynamS stdynamF dsname $50 varname $32 label $&MAXNEWLABELLEN byvars $100  ; 
                 call missing(stdynamS, stdynamF, dsname, varname, label, count, byvars, critvarfl); 
				 &BVLCLAUSE; &BVMCLAUSE;
				 stop; run;  
  data newmeansout1; length stdynamS stdynamF dsname $50 varname $32 label $&MAXNEWLABELLEN byvars $100  ; 
                 call missing(stdynamS, stdynamF, dsname, varname, label, byvars, critvarfl); 
				 &BVLCLAUSE; &BVMCLAUSE;
				 stop; run;  
				 
 
  data newmeansoutMT; set newmeansout1; run;		 
  data oldmeansoutMT; set oldmeansout1; run;		 

  *======== Finished Building clause of all byvars used in this dataset;

  
  %let CXNPLUS1=1;  *if we find no execute strings, this does the right thing;
  
  
 /* For old and for new
  * 1) sort, so we canuse the by statement in proc means.
  * 2) run proc means
  * 3) Add vars to the proc means dataset
  * 4) append new dataset to accumulating dataset.  
  *    Also append empty (MT) dataset, to be sure all the vars are defined if new dataset is blank.
  */
  data cexecstrs(label="Contents Execute Strings");
    set cexecstrs end=eof;
    length oldsortclause newsortclause $500 execstr $5000;
	nplus1=_N_+1;
	if ^missing(byvars) then do; oldsortclause=catx(' ', cats("proc sort data=oldlib.", dsname), "out=myoldds; by", byvars, "; run;");
	                             newsortclause=catx(' ', cats("proc sort data=newlib.", dsname), "out=mynewds; by", byvars, "; run;");
								 end;
	                    else do; oldsortclause=catx(' ', "data myoldds;", cats("set oldlib.", dsname), "; run;");
						         newsortclause=catx(' ', "data mynewds;", cats("set newlib.", dsname), "; run;");
								 end;
    execstr = catx(' ', cats("%", "nrstr("),
						oldsortclause,
	                    "proc means data=myoldds stackodsoutput n mean median max min range std nmiss; var", varname, 
							 "; ", byclause, "; ods output summary=", cats("_oldmnsout", vvalue(_N_)), "; run;",
						"data", cats("_oldmnsout", vvalue(_N_)), "; length variable $40 label $&MAXNEWLABELLEN; set ", cats("_oldmnsout", vvalue(_N_)), 
							                      "oldmeansoutMT;", 
							                      cats("length stdynamS $50 varname $32 byvars $100 ; dsname='", dsname, 
												  "'; stdynamS='",stdynamS, "'; varname='", varname, "'; critvarfl=",
												  critvarfl, '; byvars="', byvars, '";'), 
												  " run;",
						"data", cats("oldmeansout", vvalue(nplus1)), "; length variable $40 label $&MAXNEWLABELLEN; set", cats("oldmeansout", vvalue(_N_)), 
							    cats("_oldmnsout", vvalue(_N_)), "; run;",
						"proc datasets library=work nolist; delete", cats("_oldmnsout", vvalue(_N_)), 
							                                         cats("oldmeansout", vvalue(_N_)), "; quit; run;",

	                    newsortclause,
						"proc means data=mynewds stackodsoutput n mean median max min range std nmiss; var", varname, 
							 "; ", byclause, "; ods output summary=", cats("_newmnsout", vvalue(_N_)), "; run;",
						"data", cats("_newmnsout", vvalue(_N_)), ";  length variable $40 label $&MAXNEWLABELLEN; set", cats("_newmnsout", vvalue(_N_)), 
							                      "newmeansoutMT;",
							                      cats("length stdynamS $50 varname $32 byvars $100 ; dsname='",dsname, 
												  "'; stdynamS='",stdynamS, "'; varname='", varname, "'; critvarfl=",
												  critvarfl, '; byvars="', byvars, '";'), 
												  " run;",
				        "data", cats("newmeansout", vvalue(nplus1)), "; length variable $40 label $&MAXNEWLABELLEN; set", cats("newmeansout", vvalue(_N_)), 
							    cats("_newmnsout", vvalue(_N_)), "; run;",		
						"proc datasets library=work nolist; delete", cats("_newmnsout", vvalue(_N_)), 
							                                         cats("newmeansout", vvalue(_N_)), "; quit; run;",
						");");
	output;
	if eof then do; call symput("CXNPLUS1", strip(vvalue(nplus1)));
					end;
  run;



  %if &DEBUG=Y
      %then %do; title cexecstrs;
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
                 title3 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";
                 proc report data=cexecstrs split='~'; 
                   column execstr;
                   define execstr /display flow width=100;
                 run;
                 title;
				 %end;

 data _null_;
    set cexecstrs;
	call execute(execstr);
  run;
  
  
  data newmeansout; set newmeansout&CXNPLUS1; run;
  data oldmeansout; set oldmeansout&CXNPLUS1; run;
  


%if &DEBUG=Y
      %then %do; %let OCLAUSE=(obs=10);
				 title "oldmeansout&OCLAUSE";
	             title2 "OLDRDIR: &&OLDRDIR\data\derived\&&FRUN&i";
				 proc print data=oldmeansout&OCLAUSE;  run;
				 title "newmeansout&OCLAUSE"; 
                 title2 "newdir: &&NEWRDIR\data\derived\&&FRUN&i";				 
				 proc print data=newmeansout&OCLAUSE;  run;
				 title;
				 %end;


  proc sort data=newmeansout; by dsname varname &BYVARS4M; run;
  proc sort data=oldmeansout; by dsname varname &BYVARS4M; run;
  
  data oldfqlib.mo&&SRUN&I(label="Study means Out &&SRUN&I" sortedby=dsname varname &BYVARS4M);
    set oldmeansout;
  run;
  %if %length(&BYVARS4M)>0 %then %do; proc datasets lib=oldfqlib nolist; modify mo&&SRUN&I; xattr add ds ddiffbyvars="&BYVARS4M"; quit; %end;
                           %else %do; proc datasets lib=oldfqlib nolist; modify mo&&SRUN&I; xattr add ds ddiffbyvars=" ";         quit; %end;
  data newfqlib.mo&&SRUN&I(label="Study means Out &&SRUN&I" sortedby=dsname varname &BYVARS4M);
    set newmeansout;
  run;
  %if %length(&BYVARS4M)>0 %then %do; proc datasets lib=newfqlib nolist; modify mo&&SRUN&I; xattr add ds ddiffbyvars="&BYVARS4M"; quit; %end;
                           %else %do; proc datasets lib=newfqlib nolist; modify mo&&SRUN&I; xattr add ds ddiffbyvars=" ";         quit; %end;

%mend buildmeansout;

