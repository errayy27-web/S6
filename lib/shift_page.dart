import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
typedef ShiftRequest = Future<http.Response?> Function(String method,String path,{Object? body,String? prefer});
class ShiftPage extends StatefulWidget {
 final ShiftRequest request;
 final Map<String,dynamic> kasa;
 final String kasaDate;
 final Map<String,dynamic> kasaArchive;
 const ShiftPage({super.key,required this.request,required this.kasa,required this.kasaDate,required this.kasaArchive});
 @override State<ShiftPage> createState()=>_ShiftPageState();
}
class _ShiftPageState extends State<ShiftPage> {
 Timer? timer; DateTime date=DateTime.now(); int shift=1; int section=0; String? detailKind; bool busy=false; String error=''; bool offline=false; DateTime? lastSync; List<Map<String,dynamic>> pendingWrites=[]; Map<String,dynamic> localHistory={};
 List<Map<String,dynamic>> transactions=[],options=[],banks=[],employees=[],handoffs=[],openings=[];
 Map<String,dynamic> daily={}; Map<String,dynamic> localAccumulated={};
 String get dateKey=>date.toIso8601String().substring(0,10);
 num number(dynamic v)=>num.tryParse('$v'.replaceAll(',','.'))??0;
 String km(dynamic v)=>'${number(v).toStringAsFixed(2).replaceAll('.',',')} KM';
 List<Map<String,dynamic>> parse(String s)=>(jsonDecode(s) as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
 @override void initState(){super.initState();loadLocal();timer=Timer.periodic(const Duration(seconds:3),(_)=>refresh());}
 @override void dispose(){timer?.cancel();super.dispose();}
 Future<void> loadLocal()async{
  final p=await SharedPreferences.getInstance();
  try{
   localHistory=Map<String,dynamic>.from(jsonDecode(p.getString('ssoil_shift_cache_v2')??'{}'));
   pendingWrites=(jsonDecode(p.getString('ssoil_shift_pending_v2')??'[]') as List).map((x)=>Map<String,dynamic>.from(x)).toList();
   localAccumulated=Map<String,dynamic>.from(jsonDecode(p.getString('ssoil_shift_accumulated_v1')??'{}'));
   restoreLocal();
  }catch(_){}
  await refresh();
 }
 void restoreLocal(){
  final d=localHistory[dateKey];if(d is! Map)return;
  if(!mounted)return;
  setState((){
   List<Map<String,dynamic>> rows(String k)=>((d[k] as List?)??[]).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
   transactions=rows('transactions');options=rows('options');banks=rows('banks');employees=rows('employees');handoffs=rows('handoffs');openings=rows('openings');
   daily=Map<String,dynamic>.from((d['daily'] as Map?)??{});
  });
 }
 Future<void> persistLocal()async{
  localHistory[dateKey]={'transactions':transactions,'options':options,'banks':banks,'employees':employees,'handoffs':handoffs,'openings':openings,'daily':daily};
  final p=await SharedPreferences.getInstance();
  await p.setString('ssoil_shift_cache_v2',jsonEncode(localHistory));
  await p.setString('ssoil_shift_pending_v2',jsonEncode(pendingWrites));
  await p.setString('ssoil_shift_accumulated_v1',jsonEncode(localAccumulated));
 }
 bool isRemoval(String method,String table,Object? data)=>
  method=='DELETE'&&table=='ssoil_shift_handoffs'||
  method=='PATCH'&&table=='ssoil_shift_transactions'&&data is Map&&data.containsKey('deleted_at');
 String removalFilter(String method,String table,Object? data,String filter){
  if(!isRemoval(method,table,data))return filter;
  return filter.replaceFirst(RegExp(r'&revision=eq\.[^&]+'),'');
 }
 Future<bool> removalConfirmed(String method,String table,Object? data,String filter)async{
  if(!isRemoval(method,table,data))return false;
  final id=RegExp(r'id=eq\.([^&]+)').firstMatch(filter)?.group(1);
  if(id==null)return false;
  try{
   final rows=await fetch(table,'id=eq.$id');
   if(method=='DELETE')return rows.isEmpty;
   return rows.length==1&&rows.first['deleted_at']!=null;
  }catch(_){return false;}
 }
 Future<void> flushPending()async{
  if(pendingWrites.isEmpty)return;
  for(final op in List<Map<String,dynamic>>.from(pendingWrites)){
   try{
    final method=op['method'].toString(),table=op['table'].toString();
    final filter=removalFilter(method,table,op['data'],op['filter'].toString());
    final r=await widget.request(method,table+filter,body:op['data'],prefer:'return=representation');
    final accepted=r!=null&&r.statusCode>=200&&r.statusCode<300&&r.body.trim()!='[]';
    if(!accepted&&!await removalConfirmed(method,table,op['data'],filter))break;
    pendingWrites.remove(op);
    final p=await SharedPreferences.getInstance();
    await p.setString('ssoil_shift_pending_v2',jsonEncode(pendingWrites));
   }catch(_){break;}
  }
 }
 Future<List<Map<String,dynamic>>> fetch(String table,String filter)async{
  final r=await widget.request('GET',table+'?select=*&'+filter);
  if(r==null||r.statusCode!=200)throw Exception(r?.body??'Bağlantı yok');
  return parse(r.body);
 }
 bool autoCloseRunning=false;
 String dateOnly(DateTime d)=>d.toIso8601String().substring(0,10);
 Future<void> autoCloseThirdShift()async{
  if(autoCloseRunning||busy||offline||pendingWrites.isNotEmpty)return;
  final now=DateTime.now();
  if(dateKey!=dateOnly(now))return;
  final yesterday=dateOnly(now.subtract(const Duration(days:1)));
  final raw=widget.kasaArchive[yesterday];
  if(raw is! Map)return;
  final kasa=Map<String,dynamic>.from(raw);
  if(kasa['cash']==null||kasa['card']==null||kasa['cash_fuel']==null||
     kasa['cash_market']==null||kasa['mtel_dopuna']==null||kasa['aero_dopuna']==null)return;
  autoCloseRunning=true;
  try{
   final found=await fetch('ssoil_shift_handoffs','business_date=eq.$yesterday&shift_number=eq.3');
   if(found.isNotEmpty)return;
   final dailyRows=await fetch('ssoil_shift_daily','business_date=eq.$yesterday');
   final tx=await fetch('ssoil_shift_transactions','business_date=eq.$yesterday&deleted_at=is.null');
   num delta=0;
   for(final t in tx){
    if(t['kind']=='cash_collection')delta+=number(t['amount']);
    if(t['kind']=='cash_expense')delta-=number(t['amount']);
   }
   final carry=dailyRows.isEmpty?0:number(dailyRows.first['cash_carryover']);
   final expected=carry+number(kasa['cash'])+delta;
   final closeTime=DateTime(now.year,now.month,now.day).toUtc().toIso8601String();
   final record={'business_date':yesterday,'shift_number':3,
    'employee_name':'3. Vardiya','closed_at':closeTime,
    'expected_cash':expected,'delivered_cash':null,'status':'pending_delivery',
    'snapshot':{'source':'daily_kasa_archive','date':yesterday,
      'cash':kasa['cash'],'card':kasa['card'],'cash_fuel':kasa['cash_fuel'],
      'cash_market':kasa['cash_market'],'mtel_dopuna':kasa['mtel_dopuna'],
      'aero_dopuna':kasa['aero_dopuna'],'fuel_sales':kasa['fuel_sales'],
      'market_sales':kasa['market_sales'],'delivered_pending':true}};
   await save('POST','ssoil_shift_handoffs',[record]);
  }catch(_){}
  finally{autoCloseRunning=false;}
 }
 Future<void> nextDayCarry(Map<String,dynamic> old,num delivered)async{
  final now=DateTime.now();
  final yesterday=dateOnly(now.subtract(const Duration(days:1)));
  if('${old['business_date']}'!=yesterday||number(old['shift_number'])!=3)return;
  final today=dateOnly(now);
  final rows=await fetch('ssoil_shift_daily','business_date=eq.$today');
  final amount=double.parse(delivered.toStringAsFixed(2));
  if(rows.isEmpty)await save('POST','ssoil_shift_daily',[{'business_date':today,'cash_carryover':amount}]);
  else await save('PATCH','ssoil_shift_daily',{'cash_carryover':amount},
    filter:'?business_date=eq.$today&revision=eq.${rows.first['revision']}');
 }
 Future<void> refresh()async{
  if(busy||!mounted)return;busy=true;
  try{
   await flushPending();
   final requestedDate=dateKey;
   final v=await Future.wait([
    fetch('ssoil_shift_transactions','business_date=eq.'+dateKey+'&deleted_at=is.null&order=created_at.desc'),
    fetch('ssoil_shift_options','deleted_at=is.null&order=sort_order.asc'),
    fetch('ssoil_shift_banks','deleted_at=is.null&order=sort_order.asc'),
    fetch('ssoil_shift_employees','deleted_at=is.null&order=name.asc'),
    fetch('ssoil_shift_handoffs','business_date=eq.'+dateKey),
    fetch('ssoil_shift_daily','business_date=eq.'+dateKey),
    fetch('ssoil_shift_bank_opening','business_date=eq.'+dateKey)
   ]);
   if(mounted&&dateKey==requestedDate)setState((){transactions=v[0];options=v[1];banks=v[2];employees=v[3];handoffs=v[4];daily=v[5].isEmpty?{}:v[5].first;openings=v[6];error='';offline=false;lastSync=DateTime.now();});
   if(dateKey==requestedDate)await persistLocal();
  }catch(e){if(mounted)setState((){error='Çevrimdışı: yerel kayıtlar gösteriliyor';offline=true;});}
  finally{busy=false;}
  if(mounted&&dateKey==dateOnly(DateTime.now()))Future.microtask(autoCloseThirdShift);
 }
 Future<void> save(String method,String table,Object data,{String filter=''})async{
  if(busy)return;busy=true;
  final op=<String,dynamic>{'method':method,'table':table,'data':data,'filter':filter};
  try{
   final effectiveFilter=removalFilter(method,table,data,filter);
   final r=await widget.request(method,table+effectiveFilter,body:data,prefer:'return=representation');
   final accepted=r!=null&&r.statusCode>=200&&r.statusCode<300&&r.body.trim()!='[]';
   if(!accepted&&!await removalConfirmed(method,table,data,effectiveFilter))throw Exception(r?.body??'Bağlantı yok');
  }catch(e){
   pendingWrites.add(op);
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('İşlem çevrimdışı kuyruğa alındı. Bağlanınca gönderilecek.')));
  }finally{busy=false;await persistLocal();await refresh();}
 }
 List<String> labels(String code)=>options.where((x)=>x['list_code']==code).map((x)=>x['label'].toString()).toList();
 Future<void> editTransaction(String kind,[Map<String,dynamic>? old])async{
  String a=old?['first_value']?.toString()??'',b=old?['second_value']?.toString()??'',bank=old?['bank_id']?.toString()??'';
  final amount=TextEditingController(text:old?['amount']?.toString()??'');
  final desc=TextEditingController(text:old?['description']?.toString()??'');
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,change)=>AlertDialog(
   title:Text(old==null?'Yeni işlem':'İşlem düzenle'),
   content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
    DropdownButtonFormField<String>(value:labels('T').contains(a)?a:null,isExpanded:true,decoration:const InputDecoration(labelText:'Kategori T'),items:labels('T').map((v)=>DropdownMenuItem(value:v,child:Text(v,overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>change(()=>a=v??'')),
    DropdownButtonFormField<String>(value:labels('W').contains(b)?b:null,isExpanded:true,decoration:const InputDecoration(labelText:'Hesap W'),items:labels('W').map((v)=>DropdownMenuItem(value:v,child:Text(v,overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>change(()=>b=v??'')),
    if(kind.startsWith('bank'))DropdownButtonFormField<String>(value:banks.any((v)=>v['id']==bank)?bank:null,isExpanded:true,decoration:const InputDecoration(labelText:'Banka Y'),items:banks.map((v)=>DropdownMenuItem(value:v['id'].toString(),child:Text(v['name'].toString()))).toList(),onChanged:(v)=>change(()=>bank=v??'')),
    TextField(controller:desc,decoration:const InputDecoration(labelText:'Açıklama')),
    TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tutar KM')),
   ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))])));
  if(ok!=true)return;
  final value=num.tryParse(amount.text.replaceAll(',','.'));
  if(a.isEmpty||b.isEmpty||value==null||value<0||(kind.startsWith('bank')&&bank.isEmpty)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Zorunlu alanları doldurun')));return;}
  final data={'business_date':dateKey,'shift_number':shift,'kind':kind,'first_value':a,'second_value':b,'bank_id':bank.isEmpty?null:bank,'amount':value,'description':desc.text};
  if(old==null){await save('POST','ssoil_shift_transactions',[data]);}
  else{await save('PATCH','ssoil_shift_transactions',data,filter:'?id=eq.'+old['id'].toString()+'&revision=eq.'+old['revision'].toString());}
 }
 Future<void> deleteTransaction(Map<String,dynamic> row)async{
  await save('PATCH','ssoil_shift_transactions',{'deleted_at':DateTime.now().toUtc().toIso8601String()},filter:'?id=eq.'+row['id'].toString()+'&revision=eq.'+row['revision'].toString());
 }
 Future<void> editNumber(String title,String table,String filter,Map<String,dynamic> data,String field,dynamic previous)async{
  final c=TextEditingController(text:number(previous??0).toStringAsFixed(2).replaceAll('.',','));
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:Text(title),content:TextField(controller:c,keyboardType:const TextInputType.numberWithOptions(decimal:true)),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))]));
  if(ok!=true)return;final value=num.tryParse(c.text.replaceAll(',','.'));if(value==null||value<0)return;
  data[field]=double.parse(value.toStringAsFixed(2));
  final exists=previous!=null;
  await save(exists?'PATCH':'POST',table,exists?{field:data[field]}:[data],filter:exists?filter:'');
 }
 num sum(String kind)=>transactions.where((v)=>v['kind']==kind&&v['shift_number']==shift).fold<num>(0,(a,v)=>a+(num.tryParse(v['amount'].toString())??0));
 // Kasada Biriken is device-local. Only the combined handoff amount reaches Supabase.
 String accumulatedKey(int n)=>'$dateKey:$n';
 List<Map<String,dynamic>> accumulatedRows(int n){
  final raw=localAccumulated[accumulatedKey(n)];
  if(raw is! List)return [];
  return raw.map((e)=>Map<String,dynamic>.from(e as Map)).toList();
 }
 num accumulatedSum(int n)=>accumulatedRows(n).fold<num>(0,(v,r)=>v+number(r['amount']));
 Future<void> editAccumulated([Map<String,dynamic>? old])async{
  final amount=TextEditingController(text:old==null?'':number(old['amount']).toStringAsFixed(2).replaceAll('.',','));
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:Text(old==null?'Kasada Biriken Ekle':'Kasada Biriken Düzelt'),content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
   const Text('Kategori T: KASADA BİRİKEN'),
   const Text('Hesap W: PETROL'),
   const Text('Açıklama: Kasada biriken fazla para'),
   TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tutar KM')),
  ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))]));
  if(ok!=true)return;
  final value=num.tryParse(amount.text.replaceAll(',','.'));
  if(value==null||value<0)return;
  final rows=accumulatedRows(shift);
  final item={'id':old?['id']??DateTime.now().microsecondsSinceEpoch.toString(),'amount':double.parse(value.toStringAsFixed(2)),'first_value':'KASADA BİRİKEN','second_value':'PETROL','description':'Kasada biriken fazla para'};
  final index=rows.indexWhere((r)=>r['id']==item['id']);
  if(index<0){rows.add(item);}else{rows[index]=item;}
  setState(()=>localAccumulated[accumulatedKey(shift)]=rows);
  await persistLocal();
 }
 Future<void> deleteAccumulated(Map<String,dynamic> item)async{
  final rows=accumulatedRows(shift)..removeWhere((r)=>r['id']==item['id']);
  setState(()=>localAccumulated[accumulatedKey(shift)]=rows);
  await persistLocal();
 }
 Map<String,dynamic>? handoffFor(int n){
  final rows=handoffs.where((h)=>number(h['shift_number'])==n).toList();
  return rows.isEmpty?null:rows.first;
 }
 num carryFor(int n){
  if(n==1)return number(daily['cash_carryover']);
  final previous=handoffFor(n-1);
  return previous==null||previous['delivered_cash']==null?0:number(previous['delivered_cash']);
 }
 Map<String,dynamic> get datedKasa {final v=widget.kasaArchive[dateKey];return v is Map?Map<String,dynamic>.from(v):dateKey==widget.kasaDate?widget.kasa:<String,dynamic>{};}
 num currentCashSales()=>number(datedKasa['cash_fuel'])+number(datedKasa['cash_market']);
 num currentDopuna()=>number(datedKasa['mtel_dopuna'])+number(datedKasa['aero_dopuna']);
 num cashSnapshot(int n,String key){
  if(n<=0)return 0;
  final h=handoffFor(n);
  if(h==null)return 0;
  return number((h['snapshot'] is Map)?(h['snapshot'] as Map)[key]:null);
 }
 num shiftSales(int n,String key,num current){
  if(n==1)return current;
  return current-cashSnapshot(n-1,key);
 }
 num shiftExpected(int n){
  final base=carryFor(n);
  final sales=shiftSales(n,'cash_sales',currentCashSales());
  final dopuna=shiftSales(n,'dopuna',currentDopuna());
  final collection=transactions.where((t)=>t['kind']=='cash_collection'&&number(t['shift_number'])==n).fold<num>(0,(v,t)=>v+number(t['amount']));
  final expense=transactions.where((t)=>t['kind']=='cash_expense'&&number(t['shift_number'])==n).fold<num>(0,(v,t)=>v+number(t['amount']));
  return base+sales+dopuna+collection-expense-accumulatedSum(n);
 }
 Future<void> handoff()async{
  final old=handoffFor(shift);
  final name=TextEditingController(text:old?['employee_name']?.toString()??'');
  final delivered=TextEditingController(text:old==null||old['delivered_cash']==null?'':(number(old['delivered_cash'])-accumulatedSum(shift)).toStringAsFixed(2).replaceAll('.',','));
  final initial=old==null?DateTime.now():(DateTime.tryParse('${old['closed_at']}')?.toLocal()??DateTime.now());
  final closeTime=TextEditingController(text:'${initial.hour.toString().padLeft(2,'0')}:${initial.minute.toString().padLeft(2,'0')}:${initial.second.toString().padLeft(2,'0')}');
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:Text(old==null?'Vardiya Devir':'Vardiya Devir Düzelt'),content:Column(mainAxisSize:MainAxisSize.min,children:[
   TextField(controller:name,decoration:const InputDecoration(labelText:'Çalışan adı')),
   TextField(controller:delivered,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Teslim edilen nakit KM')),
   TextField(controller:closeTime,decoration:const InputDecoration(labelText:'Kapanış saati SS:DD:SN')),
  ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))]));
  if(ok!=true)return;
  final value=num.tryParse(delivered.text.replaceAll(',','.'));
  if(value==null||value<0||name.text.trim().isEmpty)return;
  final bits=closeTime.text.trim().split(':');
  if(bits.length!=3)return;
  final h=int.tryParse(bits[0]),m=int.tryParse(bits[1]),sec=int.tryParse(bits[2]);
  if(h==null||m==null||sec==null||h<0||h>23||m<0||m>59||sec<0||sec>59)return;
  final stamp=DateTime(date.year,date.month,date.day,h,m,sec).toUtc().toIso8601String();
  final combined=value+accumulatedSum(shift);
  final expected=old==null?shiftExpected(shift):number(old['expected_cash']);
  final data={'business_date':dateKey,'shift_number':shift,'employee_name':name.text.trim(),'status':'closed','closed_at':stamp,'expected_cash':expected,'delivered_cash':combined,'snapshot':{'cash_sales':currentCashSales(),'dopuna':currentDopuna(),'cash_collection':sum('cash_collection'),'cash_expense':sum('cash_expense'),'bank_collection':sum('bank_collection'),'bank_expense':sum('bank_expense')}};
  if(old==null){await save('POST','ssoil_shift_handoffs',[data]);}
  else{data['snapshot']=old['snapshot'];
   if(old['status']=='pending_delivery')data['status']='closed';
   await save('PATCH','ssoil_shift_handoffs',data,filter:'?id=eq.'+old['id'].toString()+'&revision=eq.'+old['revision'].toString());
   if(old['status']=='pending_delivery')await nextDayCarry(old,value);
  }
 }
 Future<void> deleteHandoff(Map<String,dynamic> row)async{
  final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
   title:const Text('Vardiya kaydını sil'),
   content:Text('${row['shift_number']}. vardiya kaydı silinsin mi?'),
   actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),
    TextButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Sil'))]));
  if(confirm!=true)return;
  await save('DELETE','ssoil_shift_handoffs',{},
   filter:'?id=eq.${row['id']}&revision=eq.${row['revision']}');
 }
 num total(String kind)=>transactions.where((v)=>v['kind']==kind).fold<num>(0,(a,v)=>a+number(v['amount']));
 num bankTotal(String kind,String id)=>transactions.where((v)=>v['kind']==kind&&v['bank_id'].toString()==id).fold<num>(0,(a,v)=>a+number(v['amount']));
 Widget line(String title,dynamic amount,{String? kind}){
  return ListTile(dense:true,title:Text(title),trailing:Row(mainAxisSize:MainAxisSize.min,children:[
   Text(km(amount)),if(kind!=null)TextButton(onPressed:()=>setState(()=>detailKind=detailKind==kind?null:kind),child:const Text('Göster'))
  ]));
 }
 Widget detail(){
  const names={'cash_expense':'Nakit Harcamalar','bank_expense':'Banka Harcamaları','cash_collection':'Nakit Tahsilatlar','bank_collection':'Banka Tahsilatları'};
  final rows=transactions.where((x)=>x['kind']==detailKind&&(section!=2||x['shift_number']==shift)).toList();
  return Column(children:[
   ListTile(title:Text(names[detailKind]??''),trailing:IconButton(icon:const Icon(Icons.close),onPressed:()=>setState(()=>detailKind=null))),
   FilledButton.icon(onPressed:()=>editTransaction(detailKind!),icon:const Icon(Icons.add),label:const Text('Yeni Ekle')),
   for(final x in rows)Card(child:ListTile(title:Text(km(x['amount'])),subtitle:Text('${x['description']} / ${x['first_value']} / ${x['second_value']}'),trailing:Wrap(children:[
    IconButton(icon:const Icon(Icons.edit),onPressed:()=>editTransaction(detailKind!,x)),
    IconButton(icon:const Icon(Icons.delete_outline),onPressed:()=>deleteTransaction(x))
   ]))),
  ]);
 }
 Widget bankRows()=>Card(child:Column(children:[
  const ListTile(title:Text('BANKALAR — Açılış Bakiyeleri',style:TextStyle(fontWeight:FontWeight.bold))),
  for(final bank in banks)Builder(builder:(ctx){
   final rows=openings.where((v)=>v['bank_id']==bank['id']).toList();
   final opening=rows.isEmpty?null:rows.first['opening_balance'];
   final id=bank['id'].toString();
   return Column(children:[
    ListTile(title:Text(bank['name'].toString()),subtitle:Text('Açılış: ${km(opening)} • Güncel: ${km(number(opening)+bankTotal('bank_collection',id)-bankTotal('bank_expense',id))}'),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:()=>editNumber('Banka açılış','ssoil_shift_bank_opening','?business_date=eq.$dateKey&bank_id=eq.$id',{'business_date':dateKey,'bank_id':id},'opening_balance',opening))),
    line('Banka tahsilatları',bankTotal('bank_collection',id),kind:'bank_collection'),
    line('Banka harcamaları',bankTotal('bank_expense',id),kind:'bank_expense'),
   ]);
  })
 ]));
 Widget summary()=>Column(children:[
  Card(child:Column(children:[
   const ListTile(title:Text('GÜNLÜK KASA ÖZETİ',style:TextStyle(fontWeight:FontWeight.bold))),
   ListTile(title:const Text('Gün başı nakit devir'),subtitle:Text(km(daily['cash_carryover'])),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:()=>editNumber('Nakit devir','ssoil_shift_daily','?business_date=eq.$dateKey',{'business_date':dateKey},'cash_carryover',daily['cash_carryover']))),
   line('Nakit yakıt',widget.kasa['cash_fuel']),
   line('Nakit market',widget.kasa['cash_market']),
   line('MTEL',widget.kasa['mtel_dopuna']),
   line('AERO',widget.kasa['aero_dopuna']),
   line('Nakit tahsilatlar',total('cash_collection'),kind:'cash_collection'),
   line('TOPLAM NAKİT',number(daily['cash_carryover'])+number(widget.kasa['cash'])+total('cash_collection')),
   line('Nakit harcamalar',total('cash_expense'),kind:'cash_expense'),
   Row(children:[
    Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[const Text('Olması Gereken Nakit'),Text(km(number(daily['cash_carryover'])+number(widget.kasa['cash'])+total('cash_collection')-total('cash_expense')),style:const TextStyle(fontWeight:FontWeight.bold))])))),
    Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[const Text('Kredi Kartı'),Text(km(widget.kasa['card']),style:const TextStyle(fontWeight:FontWeight.bold))]))))
   ]),
  ])),
  bankRows(),
  const Card(child:ListTile(title:Text('Gün Sonu Tutarları'),subtitle:Text('Nakit, kredi kartı ve banka gün sonu kayıtları ayrıca eklenecek.'))),
 ]);
 Widget handoffPage(){
  final cashSales=shiftSales(shift,'cash_sales',currentCashSales());
  final dopuna=shiftSales(shift,'dopuna',currentDopuna());
  final collections=sum('cash_collection'),expenses=sum('cash_expense'),accumulated=accumulatedSum(shift);
  final totalCash=carryFor(shift)+cashSales+dopuna+collections;
  final saved=handoffFor(shift);
  final expected=saved==null?totalCash-expenses-accumulated:number(saved['expected_cash']);
  final delivered=saved==null||saved['delivered_cash']==null?null:number(saved['delivered_cash'])-accumulated;
  final diff=delivered==null?null:expected-delivered;
  return Column(children:[
   Wrap(spacing:8,children:[for(var i=1;i<=3;i++)ChoiceChip(label:Text('$i. Vardiya'),selected:shift==i,onSelected:(_)=>setState((){shift=i;detailKind=null;}))]),
   line('Nakit devir',carryFor(shift)),
   line('Nakit yakıt + market',cashSales),
   line('MTEL + AERO',dopuna),
   line('Nakit tahsilatlar',collections,kind:'cash_collection'),
   line('TOPLAM NAKİT',totalCash),
   line('Nakit harcamalar',expenses,kind:'cash_expense'),
   ListTile(title:const Text('Kasada Biriken'),subtitle:Text(km(accumulated)),trailing:TextButton(onPressed:()=>setState(()=>detailKind=detailKind=='accumulated'?null:'accumulated'),child:const Text('Göster'))),
   if(detailKind=='accumulated')Column(children:[
    FilledButton.icon(onPressed:()=>editAccumulated(),icon:const Icon(Icons.add),label:const Text('Kasada Biriken Ekle')),
    for(final item in accumulatedRows(shift))ListTile(title:Text(km(item['amount'])),subtitle:const Text('PETROL • Kasada biriken fazla para'),trailing:Wrap(children:[
     IconButton(onPressed:()=>editAccumulated(item),icon:const Icon(Icons.edit)),
     IconButton(onPressed:()=>deleteAccumulated(item),icon:const Icon(Icons.delete_outline))
    ])),
   ]),
   line('Teslim Edilmesi Gereken Nakit',expected),
   if(saved!=null&&saved['delivered_cash']!=null)...[
    line('Teslim Edilen',delivered),
    line('Kasada Biriken Dahil Devir',saved['delivered_cash']),
    ListTile(title:Text(diff!>0?'Eksik':diff<0?'Fazla':'Fark'),trailing:Text(km(diff.abs()))),
   ],
   line('Kredi Kartı',datedKasa['card']),
   FilledButton.icon(onPressed:handoff,icon:const Icon(Icons.check),label:Text(saved==null?'Vardiya Devri Kaydet':'Vardiya Devrini Düzelt')),
   for(final h in handoffs)ListTile(
   title:Text('${h['shift_number']}. Vardiya - ${h['employee_name']}'),
   subtitle:Text('Devir: ${h['delivered_cash']==null?'Henüz girilmedi':km(h['delivered_cash'])} / Beklenen: ${km(h['expected_cash'])}'),
   onTap:(){setState(()=>shift=number(h['shift_number']).toInt());handoff();},
   trailing:Wrap(children:[
    IconButton(tooltip:'Düzenle',icon:const Icon(Icons.edit_outlined),
     onPressed:(){setState(()=>shift=number(h['shift_number']).toInt());handoff();}),
    IconButton(tooltip:'Sil',icon:const Icon(Icons.delete_outline),
     onPressed:()=>deleteHandoff(h))
   ])),
  ]);
 }
 @override Widget build(BuildContext context){
  return ListView(children:[
   Row(children:[Expanded(child:OutlinedButton.icon(icon:const Icon(Icons.calendar_month),label:Text(dateKey),onPressed:()async{final d=await showDatePicker(context:context,initialDate:date,firstDate:DateTime(2020),lastDate:DateTime(2100));if(d!=null){setState((){date=d;transactions=[];handoffs=[];openings=[];daily={};detailKind=null;});restoreLocal();refresh();}})),IconButton(onPressed:refresh,icon:const Icon(Icons.refresh))]),
   if(offline)const ListTile(leading:Icon(Icons.wifi_off),title:Text('Çevrimdışı — kayıtlar telefonda saklanıyor')),
   if(pendingWrites.isNotEmpty)Text('${pendingWrites.length} işlem senkronizasyon bekliyor'),
   if(lastSync!=null)Text('Son senkronizasyon: ${lastSync!.hour.toString().padLeft(2,'0')}:${lastSync!.minute.toString().padLeft(2,'0')}'),
   if(section!=0)TextButton.icon(onPressed:()=>setState((){section=0;detailKind=null;}),icon:const Icon(Icons.arrow_back),label:const Text('Vardiya Yönetimi')),
   if(section==0)...[
    const ListTile(title:Text('VARDİYA YÖNETİMİ',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),
    line('Anlık olması gereken nakit',number(daily['cash_carryover'])+number(datedKasa['cash'])+total('cash_collection')-total('cash_expense')),
    line('Kredi kartı',datedKasa['card']),
    for(final k in ['cash_expense','bank_expense','cash_collection','bank_collection'])
     OutlinedButton(onPressed:()=>setState(()=>detailKind=k),child:Text({'cash_expense':'Nakit Harcamalar','bank_expense':'Banka Harcamaları','cash_collection':'Nakit Tahsilatlar','bank_collection':'Banka Tahsilatları'}[k]!)),
    FilledButton(onPressed:()=>setState(()=>section=1),child:const Text('1. Bölüm — Günlük Kasa ve Bankalar')),
    FilledButton(onPressed:()=>setState(()=>section=2),child:const Text('2. Bölüm — Vardiya Devri')),
   ],
   if(section==1)summary(),
   if(section==2)handoffPage(),
   if(detailKind!=null&&detailKind!='accumulated')detail(),
  ]);
 }
}
