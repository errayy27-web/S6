import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
typedef ShiftRequest = Future<http.Response?> Function(String method,String path,{Object? body,String? prefer});
class ShiftPage extends StatefulWidget {
 final ShiftRequest request;
 const ShiftPage({super.key,required this.request});
 @override State<ShiftPage> createState()=>_ShiftPageState();
}
class _ShiftPageState extends State<ShiftPage> {
 Timer? timer; DateTime date=DateTime.now(); int shift=1; bool busy=false; String error='';
 List<Map<String,dynamic>> transactions=[],options=[],banks=[],employees=[],handoffs=[],openings=[];
 Map<String,dynamic> daily={};
 String get dateKey=>date.toIso8601String().substring(0,10);
 num number(dynamic v)=>num.tryParse('$v')??0;
 List<Map<String,dynamic>> parse(String s)=>(jsonDecode(s) as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
 @override void initState(){super.initState();refresh();timer=Timer.periodic(const Duration(seconds:3),(_)=>refresh());}
 @override void dispose(){timer?.cancel();super.dispose();}
 Future<List<Map<String,dynamic>>> fetch(String table,String filter)async{
  final r=await widget.request('GET',table+'?select=*&'+filter);
  if(r==null||r.statusCode!=200)throw Exception(r?.body??'Bağlantı yok');
  return parse(r.body);
 }
 Future<void> refresh()async{
  if(busy||!mounted)return;busy=true;
  try{
   final v=await Future.wait([
    fetch('ssoil_shift_transactions','business_date=eq.'+dateKey+'&deleted_at=is.null&order=created_at.desc'),
    fetch('ssoil_shift_options','deleted_at=is.null&order=sort_order.asc'),
    fetch('ssoil_shift_banks','deleted_at=is.null&order=sort_order.asc'),
    fetch('ssoil_shift_employees','deleted_at=is.null&order=name.asc'),
    fetch('ssoil_shift_handoffs','business_date=eq.'+dateKey),
    fetch('ssoil_shift_daily','business_date=eq.'+dateKey),
    fetch('ssoil_shift_bank_opening','business_date=eq.'+dateKey)
   ]);
   if(mounted)setState((){transactions=v[0];options=v[1];banks=v[2];employees=v[3];handoffs=v[4];daily=v[5].isEmpty?{}:v[5].first;openings=v[6];error='';});
  }catch(e){if(mounted)setState(()=>error=e.toString());}
  finally{busy=false;}
 }
 Future<void> save(String method,String table,Object data,{String filter=''})async{
  if(busy)return;busy=true;
  try{
   final r=await widget.request(method,table+filter,body:data,prefer:'return=representation');
   if(r==null||r.statusCode<200||r.statusCode>=300)throw Exception(r?.body??'Bağlantı yok');
  }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Supabase: '+e.toString())));}
  finally{busy=false;await refresh();}
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
  final c=TextEditingController(text:previous?.toString()??'0');
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:Text(title),content:TextField(controller:c,keyboardType:const TextInputType.numberWithOptions(decimal:true)),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))]));
  if(ok!=true)return;final value=num.tryParse(c.text.replaceAll(',','.'));if(value==null)return;
  data[field]=value;
  final exists=previous!=null;
  await save(exists?'PATCH':'POST',table,exists?{field:value}:[data],filter:exists?filter:'');
 }
 num sum(String kind)=>transactions.where((v)=>v['kind']==kind&&v['shift_number']==shift).fold<num>(0,(a,v)=>a+(num.tryParse(v['amount'].toString())??0));
 Future<void> handoff()async{
  final name=TextEditingController(),delivered=TextEditingController();
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Vardiya Devir'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Çalışan adı')),TextField(controller:delivered,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Teslim nakit KM'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Kaydet'))]));
  if(ok!=true)return;final value=num.tryParse(delivered.text.replaceAll(',','.'));if(value==null||name.text.trim().isEmpty)return;
  final expected=(num.tryParse((daily['cash_carryover']??0).toString())??0)+sum('cash_collection')-sum('cash_expense');
  final data={'business_date':dateKey,'shift_number':shift,'employee_name':name.text.trim(),'status':'closed','closed_at':DateTime.now().toUtc().toIso8601String(),'expected_cash':expected,'delivered_cash':value,'difference':value-expected,'snapshot':{'cash_collection':sum('cash_collection'),'cash_expense':sum('cash_expense'),'bank_collection':sum('bank_collection'),'bank_expense':sum('bank_expense')}};
  final previous=handoffs.where((h)=>h['shift_number']==shift).toList();
  if(previous.isEmpty){await save('POST','ssoil_shift_handoffs',[data]);}
  else{await save('PATCH','ssoil_shift_handoffs',data,filter:'?id=eq.'+previous.first['id'].toString()+'&revision=eq.'+previous.first['revision'].toString());}
 }
 @override Widget build(BuildContext context){
  const kinds={'cash_expense':'Nakit Harcama','bank_expense':'Banka Harcama','cash_collection':'Nakit Tahsilat','bank_collection':'Banka Tahsilat'};
  return ListView(children:[
   Row(children:[Expanded(child:OutlinedButton.icon(icon:const Icon(Icons.calendar_month),label:Text(dateKey),onPressed:()async{final d=await showDatePicker(context:context,initialDate:date,firstDate:DateTime(2020),lastDate:DateTime(2100));if(d!=null){setState(()=>date=d);refresh();}})),IconButton(onPressed:refresh,icon:const Icon(Icons.refresh))]),
   if(error.isNotEmpty)Text(error,style:const TextStyle(color:Colors.red)),
   const Text('Supabase ile her 3 saniyede senkronizasyon',style:TextStyle(fontSize:12)),
   Wrap(spacing:8,children:[for(var i=1;i<=3;i++)ChoiceChip(label:Text('$i. Vardiya'),selected:shift==i,onSelected:(_)=>setState(()=>shift=i))]),
   Wrap(spacing:8,runSpacing:8,children:[for(final k in kinds.keys)OutlinedButton(onPressed:()=>editTransaction(k),child:Text('+ '+kinds[k]!))]),
   Card(child:Column(children:[
    ListTile(title:const Text('Nakit Gün Başı Devir'),subtitle:Text((daily['cash_carryover']??0).toString()+' KM'),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:()=>editNumber('Nakit devir','ssoil_shift_daily','?business_date=eq.'+dateKey+'&revision=eq.'+(daily['revision']??'').toString(),{'business_date':dateKey},'cash_carryover',daily['cash_carryover']))),
    for(final bank in banks)ListTile(title:Text(bank['name'].toString()),subtitle:Text('Açılış bakiyesi'),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:(){final rows=openings.where((v)=>v['bank_id']==bank['id']).toList();editNumber('Banka açılış','ssoil_shift_bank_opening','?business_date=eq.'+dateKey+'&bank_id=eq.'+bank['id'].toString()+'&revision=eq.'+(rows.isEmpty?'':rows.first['revision'].toString()),{'business_date':dateKey,'bank_id':bank['id']},'opening_balance',rows.isEmpty?null:rows.first['opening_balance']);})),
   ])),
   Card(child:Column(children:[
    for(final k in kinds.keys)ListTile(dense:true,title:Text(kinds[k]!),trailing:Text(sum(k).toStringAsFixed(2)+' KM')),
    FilledButton.icon(onPressed:handoff,icon:const Icon(Icons.check),label:const Text('Vardiya Devri Kaydet')),
    for(final h in handoffs)ListTile(title:Text(h['shift_number'].toString()+'. Vardiya - '+h['employee_name'].toString()),subtitle:Text('Durum: '+h['status'].toString()+' / Teslim: '+(h['delivered_cash']??'-').toString())),
   ])),
   for(final x in transactions.where((v)=>v['shift_number']==shift))Card(child:ListTile(title:Text((kinds[x['kind']]??'İşlem')+' - '+x['amount'].toString()+' KM'),subtitle:Text(x['first_value'].toString()+' / '+x['second_value'].toString()+'\n'+x['description'].toString()),isThreeLine:true,trailing:Wrap(mainAxisSize:MainAxisSize.min,children:[IconButton(icon:const Icon(Icons.edit),onPressed:()=>editTransaction(x['kind'].toString(),x)),IconButton(icon:const Icon(Icons.delete_outline),onPressed:()=>deleteTransaction(x))]))),
  ]);
 }
}
