(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Most common breadcrumbs, sorted by frequency. Integers are unique ids built
 * with a hash. Those are stable between runs. These breadcrumbs will be stored
 * in a bitset instead of a tree, to optimize memory usage.
 *)
let common_breadcrumbs =
  [|
    (* Tito *) 131426483086725855;
    (* ObscureUnknownCallee *) -2325599749836791251;
    (* Broadening *) -142622951265425597;
    (* TitoBroadening *) 151405570984319626;
    (* ObscureModel *) 4041077761680409843;
    (* Type[scalar] *) 2117647129174328834;
    (* Type[integer] *) 4007454346368129206;
    (* Type[bool] *) 2709449500254395549;
    (* WidenBroadening *) -293447484878671831;
    (* FormatString *) 3490955977576959699;
    (* Lambda *) -2825441026312067324;
    (* Type[enumeration] *) 4137955276530861606;
    (* SimpleVia[string_concat_rhs] *) 3884789361536239432;
    (* SimpleVia[string_concat_lhs] *) 3278089053981308067;
    (* SimpleVia[getattr] *) -1923531800511784035;
    (* SimpleVia[benign] *) 80396628513366703;
    (* SimpleVia[not_sensitive] *) -3538586240662101138;
    (* IssueBroadening *) -1136504071026855127;
    (* SimpleVia[has_first_index] *) 4107597831948140569;
    (* SimpleVia[urlencode] *) -1976186108842533500;
    (* SimpleVia[known_false_positive_5016] *) 653753269736567869;
    (* SimpleVia[urllib_quote_plus] *) 3906882568709930554;
    (* SimpleVia[escape_html] *) 910370951359474268;
    (* SimpleVia[obfuscated_data] *) -4208192405276300888;
    (* SimpleVia[hmac_key] *) -3982698479217660749;
    (* SimpleVia[filesystem_operation] *) -2972470572941736736;
    (* SimpleVia[sql_query] *) -277997400056776587;
    (* SimpleVia[bytesio] *) 2360738635902389996;
    (* ViaType[Exception] *) 311578467925302803;
    (* SimpleVia[known_false_positive_6306] *) -2854192715197321820;
    (* ViaValue[w, tag=file-open-mode] *) -981219526897552286;
    (* ViaValue[<missing>, tag=file-open-mode] *) 3681189484167054247;
    (* ViaValue[r, tag=file-open-mode] *) 3606850312773940378;
    (* SimpleVia[known_false_positive_5012] *) 1232508420104449927;
  |]


(* Most common first fields, sorted by frequency. *)
let common_first_fields =
  [|
    (* "id" *) -1579237068595228269;
    (* "get" *) -1181371377781863068;
    (* "media" *) 2793234494828713258;
    (* "location" *) 3529552762014010621;
    (* "items" *) -699490818662928217;
    (* "as_client_dict" *) -3207755474630565726;
    (* "mention" *) 638136595512949422;
    (* "title" *) 3489894656327767537;
    (* "__str__" *) 1004614813458022908;
    (* "__eq__" *) 3167653849553134142;
    (* "user" *) 1626021139687501307;
    (* "dumps" *) -2069201849497384383;
    (* "name" *) 1385878747775520664;
    (* "value" *) -3263389584657799345;
    (* "user_id" *) -1945631802289200782;
    (* "media_id" *) 3051542374354077398;
    (* "node" *) -3370422203002005925;
    (* "username" *) -834726256690366059;
    (* "users" *) 486769371546573853;
    (* "owner" *) 4568692011124080467;
    (* "__add__" *) -163382128125390609;
    (* "data" *) 2789510576071531125;
    (* "results" *) 929089458433079911;
    (* "created_at" *) 1685163853816350476;
    (* "__name__" *) -426769765421230711;
  |]
