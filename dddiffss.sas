
/*--------------------------- Seattle Genetics Standard Program Header ---------------------------*
|         Program Name: dddiffss.sas
|  Operating System(s): Windows 7 
|          SAS Version: 9.4
|                Owner: jpg
|              Purpose: Produce spreadsheet from ddiff datasets produced my mcr_osafe_derived_diff
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


%let FAST4DEBUG=Y;
%macro setup();
  %if &FAST4DEBUG=Y %then %do; %put WARNING: Skipping Init.sas because it takes forever (4+ minutes);
							   libname current 'O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\v_work\data\derived';
							   %include "O:\Projects\iSAFE\utilities\autocall\mcr_isafe_value_checker_ss.sas";
							   %end;
				    %else %do; %include "init.sas";
                               %end;
%mend;
%setup();


options mprint merror mlogic macrogen symbolgen formdlim='=' ps=max ls=210 nocenter nofmterr spool fullstimer nothreads source2;



%mcr_isafe_value_checker_ss(DDIFFDSPATH=%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\development\jpgtst\data\derived\testing\freqout),
                            OUTPATH    =%str(O:\Projects\iSAFE\iSAFE_Dev\safety_analysis_1014\development\jpgtst\data\derived\testing\freqout),
							limitmem=3,
                            OUTSUFFIX=);

