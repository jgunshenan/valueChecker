
/*--------------------------- Seattle Genetics Standard Program Header ---------------------------
|         Program Name: dddiff.sas
|  Operating System(s): Windows 7 
|          SAS Version: 9.4
|                Owner: jpg
|              Purpose:Compare Derived Date from 2 different months, and report on differences.
|                       
|  Inputs Path\Name(s): 
|                       
| Outputs Path\Name(s): 
|                       
|---------------------------------------- Macro Programs ----------------------------------------
| Intended Macro Usage: 
|         Dependencies: 
|         Restrictions: 
|                           --- Macro Parameters : Parameter Description ---
|  
|------------------------------ Post-Testing Modifications History ------------------------------
|  Mod. Date   User Name      Modification
|  
|------------------------------------------------------------------------------------------------*/

options fullstimer;

options mprint merror mlogic macrogen symbolgen formdlim='=' ps=max ls=175 nocenter nofmterr spool fullstimer nothreads;

%let FAST4DEBUG=Y;
%macro setup();
  %if &FAST4DEBUG=Y %then %do; %put WARNING: Skipping Init.sas because it takes forever (4+ minutes);
                               libname l "O:\Projects\iSAFE\utilities\lookups";
							   libname current 'O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived';
							   %include "O:\Projects\iSAFE\utilities\autocall\mcr_isafe_value_checker.sas";
							   %end;
				    %else %do; %include "init.sas";
                               %end;
%mend;
%setup();


options mprint merror mlogic macrogen symbolgen formdlim='=' ps=max ls=175 nocenter nofmterr spool fullstimer nothreads;



%mcr_isafe_value_checker(oldrdir=%str(O:\Projects\iSAFE\iSAFE_Prod\safety_analysis_1014\v2022_04),
					     newrdir=%str(O:\Projects\iSAFE\iSAFE_Prod\safety_analysis_1014\v2022_05),
						OUTPATH=%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\development\jpgtst\data\derived\testing\freqout),
					    IDSPATH=%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived\testing\freqout), /* Intermediate Datasets, freqout and meansout */
						debug=Y,
						alwaysbuild=N,
						outsuffix=
					    );


