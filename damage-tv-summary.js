/* Read-only damage summary views. ES5 for TV browsers. */
(function (root) {
  "use strict";
  root.GREENLOOP_DAMAGE_SUMMARY = function (api, hooks) {
    var scope = null, offset = 0, last = null, request = 0, cardRequest = 0, limit = 6;
    var titles = {today:"Today's damaged parts", month:"This month's damages", all:"All damaged parts", value:"Total damage value", payable:"This Month Payable"};
    function get(id) { return document.getElementById(id); }
    function text(id, value) { get(id).textContent = value; }
    function esc(value) { return String(value === null || value === undefined ? "" : value).replace(/[&<>"']/g, function (c) { return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]; }); }
    function money(value) { return value === null || value === undefined ? "Not recorded" : String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ","); }
    function date(value) { if (!value) return "All recorded history"; var p=value.split("-"); return p[2]+" "+["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(p[1])-1]+" "+p[0]; }
    function period(data) { return data.date_from ? date(data.date_from)+(data.date_from===data.date_to ? "" : " – "+date(data.date_to))+" · UAE" : "All recorded history · UAE dates"; }
    function values(list) { var out=[],i; for(i=0;i<list.length;i++)out.push(esc(list[i].currency)+" "+esc(money(list[i].amount)));return out.join(" · ") || "No recorded value"; }
    function cell(label, value, note) { return '<td data-label="'+esc(label)+'">'+esc(value===null || value==="" ? "Not recorded" : value)+(note ? '<small>'+esc(note)+'</small>' : '')+'</td>'; }
    function dual(original,copy) { return '<span class="damage-dual-line">Original: '+original+'</span><span class="damage-dual-line">Copy: '+copy+'</span>'; }
    function dualCell(original,copy,label) { return '<td data-label="'+label+'">'+dual(original,copy)+'</td>'; }
    function payableLabel(value) { return value===null ? 'Pending' : 'AED '+esc(money(value)); }
    function status(value) { text("damage-summary-message",value || ""); }
    function toggle() {
      get("damage-summary-detail").style.display=scope ? "block" : "none";
      get("damage-roster-heading").style.display=get("damage-employee-section").style.display=scope ? "none" : "";
      var buttons=document.querySelectorAll("[data-damage-summary]"),i;
      for(i=0;i<buttons.length;i++)buttons[i].setAttribute("aria-expanded",buttons[i].getAttribute("data-damage-summary")===scope ? "true" : "false");
    }
    function close(focus) { var previous=scope; scope=null;request++;last=null;toggle();if(focus && previous)get("damage-summary-"+previous).focus(); }
    function card(data) {
      text("damage-month",data.quantity);
      get("damage-payable").innerHTML=dual(payableLabel(data.payable),payableLabel(data.copy_payable));
      text("damage-payable-period",period(data)+(data.pending_count ? " · "+data.pending_count+" pending" : ""));
      get("damage-summary-payable").removeAttribute("data-stale");
    }
    function fatal(error) { if(hooks.expired(error)){hooks.onExpired(error);return true;}return false; }
    function render(data) {
      last=data;offset=data.offset;
      text("damage-summary-period",period(data));
      var overview=data.quantity+" damaged parts · "+data.record_count+" entries";
      var html='<span>'+esc(overview)+'</span><strong>'+dual(values(data.value_totals),values(data.copy_value_totals))+'</strong>';
      if(scope==='payable') html+='<strong class="damage-payable-total">Payable'+dual(payableLabel(data.payable),payableLabel(data.copy_payable))+'</strong>';
      if(data.unpriced_quantity || data.copy_unpriced_quantity)html+='<span>Parts without price: Original '+data.unpriced_quantity+' / Copy '+data.copy_unpriced_quantity+'</span>';
      if(scope==='payable' && (data.pending_count || data.copy_pending_count))html+='<span>Confirmed payable so far'+dual('AED '+esc(money(data.confirmed_payable)),'AED '+esc(money(data.copy_confirmed_payable)))+'</span>';
      get("damage-summary-totals").innerHTML=html;
      var payable=scope==='payable',headers=payable ? ['EMPLOYEE','DEPARTMENT','PARTS','DAMAGE VALUE','LCD PARTS','LCD ALLOWANCE','DEDUCTION','PAYABLE'] : ['DATE / TIME','EMPLOYEE','MODEL / IDENTIFIER','PART / QTY','PRICE / PART','ENTRY TOTAL','SOURCE','REASON / ENTERED BY'];
      var table='<table class="damage-summary-table"><thead><tr>',i,r;
      for(i=0;i<headers.length;i++)table+='<th scope="col">'+headers[i]+'</th>';
      table+='</tr></thead><tbody>';
      for(i=0;i<data.rows.length;i++){
        r=data.rows[i];table+='<tr>';
        if(payable){
          table+=cell('Employee',r.employee_name)+cell('Department',r.record_count ? (r.department==='glass' ? 'Glass' : r.department==='other' ? 'Other' : 'Pending') : '—')+cell('Parts',r.quantity);
          table+=dualCell(r.quantity ? values(r.value_totals) : 'AED 0.00',r.quantity ? values(r.copy_value_totals) : 'AED 0.00','Damage value');
          table+=cell('LCD parts',r.lcd_quantity)+dualCell(r.pending ? esc(r.pending) : r.waived_quantity+' LCD · AED '+money(r.waived_value)+'<small>Avg AED '+money(r.lcd_average)+'</small>',r.copy_pending ? esc(r.copy_pending) : r.waived_quantity+' LCD · AED '+money(r.copy_waived_value)+'<small>Avg AED '+money(r.copy_lcd_average)+'</small>','LCD allowance')+
            cell('Deduction',r.record_count ? 'AED '+money(r.deduction)+' per valuation' : '—')+dualCell(r.pending ? esc(r.pending) : payableLabel(r.payable),r.copy_pending ? esc(r.copy_pending) : payableLabel(r.copy_payable),'Payable');
        }else{
          table+=cell('Date / time',hooks.date(r.occurred_at))+cell('Employee',r.damaged_by,r.department==='glass' ? 'Glass' : r.department==='other' ? 'Other department' : 'Department not recorded')+
            cell('Model / identifier',r.model,r.identifier || 'Identifier not recorded')+cell('Part / qty',r.part_name,'Qty: '+r.quantity)+dualCell(esc(money(r.price_amount)+(r.currency ? ' '+r.currency : '')),esc(money(r.copy_price_amount)+(r.currency ? ' '+r.currency : '')),'Price / part')+
            dualCell(esc(money(r.entry_total)+(r.currency ? ' '+r.currency : '')),esc(money(r.copy_entry_total)+(r.currency ? ' '+r.currency : '')),'Entry total')+cell('Source',r.part_source)+cell('Reason / entered by',r.reason,r.reported_by+' · Saved '+hooks.date(r.created_at));
        }
        table+='</tr>';
      }
      if(!data.rows.length)table+='<tr><td colspan="8" class="damage-summary-empty">No damage records in this period.</td></tr>';
      get("damage-summary-table-wrap").innerHTML=table+'</tbody></table>';
      text("damage-summary-formula",payable ? 'Calculated separately for Original and Copy each month: total damage − LCD allowance − AED 100, then ÷ 2. Minimum payable: AED 0.00. Glass: up to 4 LCDs; other departments: up to 1. LCD allowance uses the quantity-weighted average. Other parts receive no allowance.' : 'Newest first · Original and Copy are separate valuations, not added together · Each row shows one saved entry; quantity may include several damaged parts.');
      text("damage-summary-range",data.result_count ? (offset+1)+'–'+Math.min(offset+data.rows.length,data.result_count)+' of '+data.result_count+(payable ? ' employees' : ' entries') : '0 entries');
      get("damage-summary-prev").disabled=offset===0;get("damage-summary-next").disabled=!data.has_more;
      get("damage-summary-retry").disabled=false;
      status(data.pending_count || data.copy_pending_count ? 'Pending calculations: Original '+(data.pending_count||0)+' / Copy '+(data.copy_pending_count||0)+'. Correct missing department, price or AED settlement. Each valuation is calculated independently.' : '');
    }
    function load(requested, retried) {
      if(!scope)return;
      var chosen=scope,ticket=++request;
      status('Loading…');get("damage-summary-prev").disabled=get("damage-summary-next").disabled=get("damage-summary-retry").disabled=true;
      api.loadDamageSummary(chosen,requested,limit,function(error,data){
        if(ticket!==request || scope!==chosen)return;
        if(error){if(fatal(error))return;status((error.message || 'Could not load this report.')+(last ? ' Previous figures remain visible.' : '')+' Select Retry.');get("damage-summary-retry").disabled=false;return;}
        if(requested && !data.rows.length && !retried){load(Math.max(0,Math.floor((data.result_count-1)/limit)*limit),true);return;}
        if(chosen==='payable')card(data);
        render(data);
      });
    }
    function open(value){
      if(!titles[value])return;
      hooks.onOpen();scope=value;offset=0;last=null;toggle();text("damage-summary-title",titles[value]);
      text("damage-summary-period",'');text("damage-summary-totals",'');text("damage-summary-table-wrap",'');text("damage-summary-formula",'');text("damage-summary-range",'');
      get("damage-summary-close").focus();load(0);
    }
    function refresh(){
      var ticket=++cardRequest;
      api.loadDamageSummary('payable',0,1,function(error,data){
        if(ticket!==cardRequest)return;
        if(error){if(fatal(error))return;text("damage-payable",'Unavailable');text("damage-payable-period",'Select to retry');get("damage-summary-payable").setAttribute("data-stale","true");return;}
        card(data);
      });
      if(scope)load(offset);
    }
    var buttons=document.querySelectorAll('[data-damage-summary]'),i;
    for(i=0;i<buttons.length;i++)buttons[i].onclick=function(){open(this.getAttribute('data-damage-summary'));};
    get("damage-summary-close").onclick=function(){close(true);};
    get("damage-summary-prev").onclick=function(){if(last && offset)load(Math.max(0,offset-limit));};
    get("damage-summary-next").onclick=function(){if(last && last.has_more)load(offset+limit);};
    get("damage-summary-retry").onclick=function(){load(offset);};
    document.addEventListener('keydown',function(event){if(scope && (event.keyCode===27 || event.keyCode===10009)){event.preventDefault();close(true);}});
    return {refresh:refresh,close:close,clear:function(){cardRequest++;close(false);text("damage-payable",'—');text("damage-payable-period",'Month to date · UAE');text("damage-summary-table-wrap",'');text("damage-summary-totals",'');status('');}};
  };
}(window));
